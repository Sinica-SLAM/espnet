#!/bin/bash

# Copyright 2020 Academia Sinica (Pin-Jui Ku, Wen-Chin Huang)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# general configuration
backend=pytorch
stage=-1
stop_stage=100
ngpu=1       # number of gpu in training
nj=8        # number of parallel jobs
dumpdir=dump # directory to dump full features
verbose=1    # verbose option (if set > 1, get more log)
seed=1       # random seed number
resume=""    # the snapshot path to resume (if set empty, no effect)

# feature extraction related
fs=16000      # sampling frequency
fmax=""       # maximum frequency
fmin=""       # minimum frequency
n_mels=80     # number of mel basis
n_fft=1024    # number of fft points
n_shift=256   # number of shift points
win_length="" # window length

# config files
train_config=conf/train_pytorch_tacotron2+spkemb.yaml
decode_config=conf/decode.yaml

# normalization related
norm_name=
cmvn=

# decoding related
model=
n_average=0 # if > 0, the model averaged with n_average ckpts will be used instead of model.loss.best
griffin_lim_iters=64  # the number of iterations of Griffin-Lim
voc=PWG                     # vocoder used (GL or PWG)

# dataset related
#db_root=downloads
db_root=../lts1/downloads

# objective evaluation related
mcep_dim=24
shift_ms=5

# exp tag
tag="" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train
dev_set=dev
eval_set=test

if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    echo "stage -1: Data and Pretrained Model Download"

    echo "Downloading data..."
    local/data_download.sh ${db_root}

    echo "Downloading essential resources..."
    local/resources_download.sh ${db_root}
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    echo "stage 0: Data preparation"
    local/data_prep.sh ${db_root}/TMSV data/all
fi

if [ -z ${norm_name} ]; then
    echo "Please specify --norm_name ."
    exit 1
fi
feat_tr_dir=${dumpdir}/${train_set}_${norm_name}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${dev_set}_${norm_name}; mkdir -p ${feat_dt_dir}
feat_ev_dir=${dumpdir}/${eval_set}_${norm_name}; mkdir -p ${feat_ev_dir}
if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    echo "stage 1: Feature Generation"

    # make train, dev and eval sets using the lists generated in data_prep.sh
    utils/subset_data_dir.sh --utt-list data/all/train_utt_list data/all data/${train_set}
    utils/fix_data_dir.sh data/${train_set}
    utils/subset_data_dir.sh --utt-list data/all/dev_utt_list data/all data/${dev_set}
    utils/fix_data_dir.sh data/${dev_set}
    utils/subset_data_dir.sh --utt-list data/all/eval_utt_list data/all data/${eval_set}
    utils/fix_data_dir.sh data/${eval_set}

    fbankdir=fbank
    for x in $train_set $dev_set $eval_set; do
        make_fbank.sh --cmd "${train_cmd}" --nj ${nj} \
            --fs ${fs} \
            --fmax "${fmax}" \
            --fmin "${fmin}" \
            --n_fft ${n_fft} \
            --n_shift ${n_shift} \
            --win_length "${win_length}" \
            --n_mels ${n_mels} \
            data/${x} \
            exp/make_fbank/${x} \
            ${fbankdir}
    done

    # compute statistics for global mean-variance normalization
    # If not using pretrained models statistics, calculate in a speaker-dependent way.
    if [ -z "${cmvn}" ]; then
        compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark
        cmvn=data/${train_set}/cmvn.ark
    fi

    # dump features for training
    dump.sh --cmd "$train_cmd" --nj ${nj} --do_delta false \
        data/${train_set}/feats.scp ${cmvn} exp/dump_feats/train ${feat_tr_dir}
    dump.sh --cmd "$train_cmd" --nj ${nj} --do_delta false \
        data/${dev_set}/feats.scp ${cmvn} exp/dump_feats/dev ${feat_dt_dir}
    dump.sh --cmd "$train_cmd" --nj ${nj} --do_delta false \
        data/${eval_set}/feats.scp ${cmvn} exp/dump_feats/eval ${feat_ev_dir}
fi

dict=data/lang_1char/${train_set}_units.txt
echo "dictionary: ${dict}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1char/
    echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    text2token.py -s 1 -n 1 data/${train_set}/text | cut -f 2- -d" " | tr " " "\n" \
        | sort | uniq | grep -v -e '^\s*$' | awk '{print $0 " " NR+1}' >> ${dict}
    wc -l ${dict}

    # make json labels
    data2json.sh --feat ${feat_tr_dir}/feats.scp \
         data/${train_set} ${dict} > ${feat_tr_dir}/data.json
    data2json.sh --feat ${feat_dt_dir}/feats.scp \
         data/${dev_set} ${dict} > ${feat_dt_dir}/data.json
    data2json.sh --feat ${feat_ev_dir}/feats.scp \
         data/${eval_set} ${dict} > ${feat_ev_dir}/data.json
fi

if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    echo "stage 3: x-vector extraction"
    # Make MFCCs and compute the energy-based VAD for each dataset
    mfccdir=mfcc
    vaddir=mfcc
    for name in ${train_set} ${dev_set} ${eval_set}; do
        utils/copy_data_dir.sh data/${name} data/${name}_mfcc_16k
        utils/data/resample_data_dir.sh 16000 data/${name}_mfcc_16k
        steps/make_mfcc.sh \
            --write-utt2num-frames true \
            --mfcc-config conf/mfcc.conf \
            --nj ${nj} --cmd "$train_cmd" \
            data/${name}_mfcc_16k exp/make_mfcc_16k ${mfccdir}
        utils/fix_data_dir.sh data/${name}_mfcc_16k
        sid/compute_vad_decision.sh --nj ${nj} --cmd "$train_cmd" \
            data/${name}_mfcc_16k exp/make_vad ${vaddir}
        utils/fix_data_dir.sh data/${name}_mfcc_16k
    done

    # Check pretrained model existence
    nnet_dir=exp/xvector_nnet_1a
    if [ ! -e ${nnet_dir} ]; then
        echo "X-vector model does not exist. Download pre-trained model."
        wget http://kaldi-asr.org/models/8/0008_sitw_v2_1a.tar.gz
        tar xvf 0008_sitw_v2_1a.tar.gz
        mv 0008_sitw_v2_1a/exp/xvector_nnet_1a exp
        rm -rf 0008_sitw_v2_1a.tar.gz 0008_sitw_v2_1a
    fi
    # Extract x-vector
    for name in ${train_set} ${dev_set} ${eval_set}; do
        sid/nnet3/xvector/extract_xvectors.sh --cmd "$train_cmd --mem 4G" --nj ${nj} \
            ${nnet_dir} data/${name}_mfcc_16k \
            ${nnet_dir}/xvectors_${name}
    done
    # Update json
    for name in ${train_set} ${dev_set} ${eval_set}; do
        local/update_json.sh ${dumpdir}/${name}_${norm_name}/data.json ${nnet_dir}/xvectors_${name}/xvector.scp
    done
fi

if [ -z ${tag} ]; then
    expname=${train_set}_${backend}_$(basename ${train_config%.*})
else
    expname=${train_set}_${backend}_${tag}
fi
expdir=exp/${expname}
if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    echo "stage 4: Text-to-speech model training"

    mkdir -p ${expdir}
    
    tr_json=${feat_tr_dir}/data.json
    dt_json=${feat_dt_dir}/data.json
    ${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        tts_train.py \
           --backend ${backend} \
           --ngpu ${ngpu} \
           --outdir ${expdir}/results \
           --tensorboard-dir tensorboard/${expname} \
           --verbose ${verbose} \
           --seed ${seed} \
           --resume ${resume} \
           --train-json ${tr_json} \
           --valid-json ${dt_json} \
           --config ${train_config}
fi

if [ -z "${model}" ]; then
    model="$(find "${expdir}" -name "snapshot*" -print0 | xargs -0 ls -t 2>/dev/null | head -n 1)"
    model=$(basename ${model})
fi
outdir=${expdir}/outputs_${model}_$(basename ${decode_config%.*})
if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
    echo "stage 5: Decoding and synthesis"

    echo "Decoding..."
    pids=() # initialize pids
    for name in ${dev_set} ${eval_set}; do
    (
        [ ! -e ${outdir}/${name} ] && mkdir -p ${outdir}/${name}
        cp ${dumpdir}/${name}_${norm_name}/data.json ${outdir}/${name}
        splitjson.py --parts ${nj} ${outdir}/${name}/data.json
        # decode in parallel
        ${train_cmd} JOB=1:${nj} ${outdir}/${name}/log/decode.JOB.log \
            tts_decode.py \
                --backend ${backend} \
                --ngpu 0 \
                --verbose ${verbose} \
                --out ${outdir}/${name}/feats.JOB \
                --json ${outdir}/${name}/split${nj}utt/data.JOB.json \
                --model ${expdir}/results/${model} \
                --config ${decode_config}
        # concatenate scp files
        for n in $(seq ${nj}); do
            cat "${outdir}/${name}/feats.$n.scp" || exit 1;
        done > ${outdir}/${name}/feats.scp
    ) &
    pids+=($!) # store background pids
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((i++)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false

    echo "Synthesis..."
    pids=() # initialize pids
    for name in ${dev_set} ${eval_set}; do
    (
        [ ! -e ${outdir}_denorm/${name} ] && mkdir -p ${outdir}_denorm/${name}
        
        # Normalization
        # If model statistics not specified, use statistics of target speaker
        if [ -z "${cmvn}" ]; then
            cmvn=data/${train_set}/cmvn.ark
        fi
        apply-cmvn --norm-vars=true --reverse=true ${cmvn} \
            scp:${outdir}/${name}/feats.scp \
            ark,scp:${outdir}_denorm/${name}/feats.ark,${outdir}_denorm/${name}/feats.scp

        # GL
        if [ ${voc} = "GL" ]; then
            echo "Using Griffin-Lim phase recovery."
            convert_fbank.sh --nj ${nj} --cmd "${train_cmd}" \
                --fs ${fs} \
                --fmax "${fmax}" \
                --fmin "${fmin}" \
                --n_fft ${n_fft} \
                --n_shift ${n_shift} \
                --win_length "${win_length}" \
                --n_mels ${n_mels} \
                --iters ${griffin_lim_iters} \
                ${outdir}_denorm/${name} \
                ${outdir}_denorm/${name}/log \
                ${outdir}_denorm/${name}/wav
        # PWG
        elif [ ${voc} = "PWG" ]; then
            echo "Using Parallel WaveGAN vocoder."

            # check existence
            voc_expdir=${db_root}/resources/pwg/
            if [ ! -d ${voc_expdir} ]; then
                echo "${voc_expdir} does not exist. Please make sure stage -1 is executed."
                exit 1
            fi

            # variable settings
            voc_checkpoint="$(find "${voc_expdir}" -name "*.pkl" -print0 | xargs -0 ls -t 2>/dev/null | head -n 1)"
            voc_conf="$(find "${voc_expdir}" -name "config.yml" -print0 | xargs -0 ls -t | head -n 1)"
            voc_stats="$(find "${voc_expdir}" -name "stats.h5" -print0 | xargs -0 ls -t | head -n 1)"
            wav_dir=${outdir}_denorm/${name}/pwg_wav
            hdf5_norm_dir=${outdir}_denorm/${name}/hdf5_norm
            [ ! -e "${wav_dir}" ] && mkdir -p ${wav_dir}
            [ ! -e ${hdf5_norm_dir} ] && mkdir -p ${hdf5_norm_dir}

            # normalize and dump them
            echo "Normalizing..."
            ${train_cmd} "${hdf5_norm_dir}/normalize.log" \
                parallel-wavegan-normalize \
                    --skip-wav-copy \
                    --config "${voc_conf}" \
                    --stats "${voc_stats}" \
                    --feats-scp "${outdir}_denorm/${name}/feats.scp" \
                    --dumpdir ${hdf5_norm_dir} \
                    --verbose "${verbose}"
            echo "successfully finished normalization."

            # decoding
            echo "Decoding start. See the progress via ${wav_dir}/decode.log."
            ${cuda_cmd} --gpu 1 "${wav_dir}/decode.log" \
                parallel-wavegan-decode \
                    --dumpdir ${hdf5_norm_dir} \
                    --checkpoint "${voc_checkpoint}" \
                    --outdir ${wav_dir} \
                    --verbose "${verbose}"

            # renaming
            rename -f "s/_gen//g" ${wav_dir}/*.wav

            echo "successfully finished decoding."
        else
            echo "Vocoder type not supported. Only GL and PWG are available."
        fi
    ) &
    pids+=($!) # store background pids
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((i++)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished."
fi

if [ ${stage} -le 6 ] && [ ${stop_stage} -ge 6 ]; then
    echo "stage 6: Objective Evaluation: MCD"

    for name in ${dev_set} ${eval_set}; do
        echo "Calculating MCD for ${name} set"
        num_of_spks=18
        all_mcds_file=${outdir}_denorm/${name}/all_mcd.log; rm -f ${all_mcds_file}

        for count_of_spk in $(seq 1 1 $num_of_spks); do
            spk=SP$(printf "%02d" $count_of_spk)

            out_wavdir=${outdir}_denorm/${name}/pwg_wav
            gt_wavdir=${db_root}/TMSV/${spk}/audio
            minf0=$(grep ${spk} conf/all.f0 | cut -f 2 -d" ")
            maxf0=$(grep ${spk} conf/all.f0 | cut -f 3 -d" ")
            out_spk_wavdir=${outdir}_denorm/mcd/${name}/pwg_out/${spk}
            gt_spk_wavdir=${outdir}_denorm/mcd/${name}/gt/${spk}
            mkdir -p ${out_spk_wavdir}
            mkdir -p ${gt_spk_wavdir}
           
            # copy wav files for mcd calculation
            for out_wav_file in $(find -L ${out_wavdir} -iname "${spk}_*" | sort ); do
                wav_basename=$(basename $out_wav_file .wav)
                cp ${out_wav_file} ${out_spk_wavdir} || exit 1
                cp ${gt_wavdir}/${wav_basename}.wav ${gt_spk_wavdir}
            done

            # actual calculation
            mcd_file=${outdir}_denorm/${name}/${spk}_mcd.log
            ${decode_cmd} ${mcd_file} \
                mcd_calculate.py \
                    --wavdir ${out_spk_wavdir} \
                    --gtwavdir ${gt_spk_wavdir} \
                    --mcep_dim ${mcep_dim} \
                    --shiftms ${shift_ms} \
                    --f0min ${minf0} \
                    --f0max ${maxf0}
            grep "Mean MCD" < ${mcd_file} >> ${all_mcds_file}
            echo "${spk}: $(grep 'Mean MCD' < ${mcd_file})"
        done
        echo "Mean MCD for ${name} set is $(awk '{ total += $3; count++ } END { print total/count }' ${all_mcds_file})"
    done
fi

if [ ${stage} -le 7 ] && [ ${stop_stage} -ge 7 ]; then
    echo "Stage 7: objective evaluation: ASR"
    
    for name in ${dev_set} ${eval_set}; do
        local/ob_eval/evaluate.sh \
            --db_root ${db_root} \
            --vocoder ${voc} \
            ${outdir} ${name}
    done
fi

