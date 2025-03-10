#!/usr/bin/env bash
#
# A short introduction about distillation framework.
#
# A typical traditional distillation method is
# Loss(teacher embedding, student embedding).
#
# Comparing to these, the proposed distillation framework contains two mainly steps:
# codebook indexes = quantizer.encode(teacher embedding)
# Loss(codebook indexes, student embedding)
#
# Things worth to meantion:
# 1. The float type teacher embedding is quantized into a sequence of
#    8-bit integer codebook indexes.
# 2. a middle layer 36(1-based) out of total 48 layers is used to extract
#    teacher embeddings.
# 3. a middle layer 6(1-based) out of total 6 layers is used to extract
#    student embeddings.
#
# To directly download the extracted codebook indexes for model distillation, you can
# set stage=2, stop_stage=4, use_extracted_codebook=True
#
# To start from scratch, you can
# set stage=0, stop_stage=4, use_extracted_codebook=False

stage=0
stop_stage=4

# Set the GPUs available.
# This script requires at least one GPU.
# You MUST set environment variable "CUDA_VISIBLE_DEVICES",
# even you only have ONE GPU. It needed by CodebookIndexExtractor to determine numbert of jobs to extract codebook indexes parallelly.

# Suppose only one GPU exists:
# export CUDA_VISIBLE_DEVICES="0"
#
# Suppose GPU 2,3,4,5 are available.
# export CUDA_VISIBLE_DEVICES="0,1,2,3"

exp_dir=./pruned_transducer_stateless6/exp
mkdir -p $exp_dir

# full_libri can be "True" or "False"
#   "True" -> use full librispeech dataset for distillation
#   "False" -> use train-clean-100 subset for distillation
full_libri=True

# use_extracted_codebook can be "True" or "False"
#   "True" -> stage 0 and stage 1 would be skipped,
#     and directly download the extracted codebook indexes for distillation
#   "False" -> start from scratch
use_extracted_codebook=True

# teacher_model_id can be one of
#   "hubert_xtralarge_ll60k_finetune_ls960" -> fine-tuned model, it is the one we currently use.
#   "hubert_xtralarge_ll60k" -> pretrained model without fintuing
teacher_model_id=hubert_xtralarge_ll60k_finetune_ls960

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ] && [ ! "$use_extracted_codebook" == "True" ]; then
  log "Stage 0: Download HuBERT model"
  # Preparation stage.

  # Install fairseq according to:
  # https://github.com/pytorch/fairseq
  # when testing this code:
  # commit 806855bf660ea748ed7ffb42fe8dcc881ca3aca0 is used.
  has_fairseq=$(python3 -c "import importlib; print(importlib.util.find_spec('fairseq') is not None)")
  if [ $has_fairseq == 'False' ]; then
    log "Please install fairseq before running following stages"
    exit 1
  fi

  # Install quantization toolkit:
  # pip install git+https://github.com/k2-fsa/multi_quantization.git
  # or
  # pip install multi_quantization

  has_quantization=$(python3 -c "import importlib; print(importlib.util.find_spec('multi_quantization') is not None)")
  if [ $has_quantization == 'False' ]; then
    log "Please install multi_quantization before running following stages"
    exit 1
  fi

  log "Download HuBERT model."
  # Parameters about model.
  hubert_model_dir=${exp_dir}/hubert_models
  hubert_model=${hubert_model_dir}/${teacher_model_id}.pt
  mkdir -p ${hubert_model_dir}
  # For more models refer to: https://github.com/pytorch/fairseq/tree/main/examples/hubert
  if [ -f ${hubert_model} ]; then
    log "HuBERT model alread exists."
  else
    wget -c https://dl.fbaipublicfiles.com/hubert/${teacher_model_id}.pt -P ${hubert_model_dir}
    wget -c wget https://dl.fbaipublicfiles.com/fairseq/wav2vec/dict.ltr.txt -P ${hubert_model_dir}
  fi
fi

if [ ! -d ./data/fbank ]; then
  log "This script assumes ./data/fbank is already generated by prepare.sh"
  exit 1
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ] && [ ! "$use_extracted_codebook" == "True" ]; then
  log "Stage 1: Verify that the downloaded HuBERT model is correct."
  # This stage is not directly used by codebook indexes extraction.
  # It is a method to "prove" that the downloaed hubert model
  # is inferenced in an correct way if WERs look like normal.
  # Expect WERs:
  # [test-clean-ctc_greedy_search] %WER 2.04% [1075 / 52576, 92 ins, 104 del, 879 sub ]
  # [test-other-ctc_greedy_search] %WER 3.71% [1942 / 52343, 152 ins, 126 del, 1664 sub ]
  ./pruned_transducer_stateless6/hubert_decode.py --exp-dir $exp_dir
fi

if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  # Analysis of disk usage:
  # With num_codebooks==8, each teacher embedding is quantized into
  # a sequence of eight 8-bit integers, i.e. only eight bytes are needed.
  # Training dataset including clean-100h with speed perturb 0.9 and 1.1 has 300 hours.
  # The output frame rates of Hubert is 50 per second.
  # Theoretically, 412M = 300 * 3600 * 50 * 8 / 1024 / 1024 is needed.
  # The actual size of all "*.h5" files storaging codebook index is 450M.
  # I think the extra "48M" usage is some meta information.

  # Time consumption analysis:
  # For quantizer training data(teacher embedding) extraction, only 1000 utts from clean-100 are used.
  # Together with quantizer training, no more than 20 minutes will be used.
  #
  # For codebook indexes extraction,
  # with two pieces of NVIDIA A100 gpus, around three hours needed to process 300 hours training data,
  # i.e. clean-100 with speed purteb 0.9 and 1.1.

  # GPU usage:
  # During quantizer's training data(teacher embedding) and it's training,
  # only the first ONE GPU is used.
  # During codebook indexes extraction, ALL GPUs set by CUDA_VISIBLE_DEVICES are used.

  if [ "$use_extracted_codebook" == "True" ]; then
    if [ ! "$teacher_model_id" == "hubert_xtralarge_ll60k_finetune_ls960" ]; then
      log "Currently we only uploaded codebook indexes from teacher model hubert_xtralarge_ll60k_finetune_ls960"
      exit 1
    fi
    # The codebook indexes to be downloaded are generated using the following setup:
    embedding_layer=36
    num_codebooks=8

    mkdir -p $exp_dir/vq
    codebook_dir=$exp_dir/vq/${teacher_model_id}_layer${embedding_layer}_cb${num_codebooks}
    mkdir -p codebook_dir
    codebook_download_dir=$exp_dir/download_codebook
    if [ -d $codebook_download_dir ]; then
      log "$codebook_download_dir exists, you should remove it first."
      exit 1
    fi
    log "Downloading extracted codebook indexes to $codebook_download_dir"
    # Make sure you have git-lfs installed (https://git-lfs.github.com)
    # The codebook indexes are generated using lhotse 1.11.0, to avoid
    # potential issues, we recommend you to use lhotse version >= 1.11.0
    lhotse_version=$(python3 -c "import lhotse; from packaging import version; print(version.parse(lhotse.version.__version__)>=version.parse('1.11.0'))")
    if [ "$lhotse_version" == "False" ]; then
      log "Expecting lhotse >= 1.11.0. This may lead to potential ID mismatch."
    fi
    git lfs install
    git clone https://huggingface.co/marcoyang/pruned_transducer_stateless6_hubert_xtralarge_ll60k_finetune_ls960 $codebook_download_dir

    vq_fbank=data/vq_fbank_layer${embedding_layer}_cb${num_codebooks}/
    mkdir -p $vq_fbank
    mv $codebook_download_dir/*.jsonl.gz $vq_fbank
    mkdir -p $codebook_dir/splits4
    mv $codebook_download_dir/*.h5 $codebook_dir/splits4/
    log "Remove $codebook_download_dir"
    rm -rf $codebook_download_dir
  fi

  ./pruned_transducer_stateless6/extract_codebook_index.py \
    --full-libri $full_libri \
    --exp-dir $exp_dir \
    --embedding-layer 36 \
    --num-utts 1000 \
    --num-codebooks 8 \
    --max-duration 100 \
    --teacher-model-id $teacher_model_id \
    --use-extracted-codebook $use_extracted_codebook

  if [ "$full_libri" == "True" ]; then
    # Merge the 3 subsets and create a full one
    rm ${vq_fbank}/librispeech_cuts_train-all-shuf.jsonl.gz
    cat <(gunzip -c ${vq_fbank}/librispeech_cuts_train-clean-100.jsonl.gz) \
      <(gunzip -c ${vq_fbank}/librispeech_cuts_train-clean-360.jsonl.gz) \
      <(gunzip -c ${vq_fbank}/librispeech_cuts_train-other-500.jsonl.gz) | \
      shuf | gzip -c > ${vq_fbank}/librispeech_cuts_train-all-shuf.jsonl.gz
  fi
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  # Example training script.
  # Note: it's better to set spec-aug-time-warpi-factor=-1
  WORLD_SIZE=$(echo ${CUDA_VISIBLE_DEVICES} | awk '{n=split($1, _, ","); print n}')
  ./pruned_transducer_stateless6/train.py \
    --manifest-dir ./data/vq_fbank \
    --master-port 12359 \
    --full-libri $full_libri \
    --spec-aug-time-warp-factor -1 \
    --max-duration 300 \
    --world-size ${WORLD_SIZE} \
    --num-epochs 20 \
    --exp-dir $exp_dir \
    --enable-distillation True
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  # Results should be similar to:
  # errs-test-clean-beam_size_4-epoch-20-avg-10-beam-4.txt:%WER = 5.67
  # errs-test-other-beam_size_4-epoch-20-avg-10-beam-4.txt:%WER = 15.60
  ./pruned_transducer_stateless6/decode.py \
    --decoding-method "modified_beam_search" \
    --epoch 20 \
    --avg 10 \
    --max-duration 200 \
    --exp-dir $exp_dir \
    --enable-distillation True
fi
