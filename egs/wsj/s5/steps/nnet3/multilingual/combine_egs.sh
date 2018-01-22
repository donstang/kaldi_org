#!/bin/bash
#
# This script generates examples for multilingual training of neural network
# using separate input egs dir per language as input.
# This scripts produces 3 sets of files --
# egs.*.scp, egs.output.*.ark, egs.weight.*.ark
#
# egs.*.scp are the SCP files of the training examples.
# egs.weight.*.ark map from the key of the example to the language-specific
# weight of that example.
# egs.output.*.ark map from the key of the example to the name of
# the output-node in the neural net for that specific language, e.g.
# 'output-2'.
#
# Begin configuration section.
cmd=run.pl
minibatch_size=512      # it is the number of consecutive egs that we take from 
                        # each source, and it only affects the locality of disk 
                        # access. This does not have to be the actual minibatch size;
num_jobs=10             # helps for better randomness across languages
                        # per archive.
frames_per_iter=400000 # this is the target number of egs in each archive of egs
                        # (prior to merging egs).  We probably should have called
                        # it egs_per_iter. This is just a guideline; it will pick
                        # a number that divides the number of samples in the
                        # entire data.
lang2weight=            # comma-separated list of weights one per 
                        # input languge to scale example's output
                        # w.r.t its input language during training.
lang2num_copies=        # comma-separated list of number of copies per 
                        # input language 
                        # This is another way to scale the effect of 
                        # a langauge especially when the language has 
                        # relatively very little data.

allocate_opts=
egs_prefix=egs.
stage=0

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# -lt 3 ]; then
  echo "Usage:$0 [opts] <num-input-langs,N> <lang1-egs-dir> ...<langN-egs-dir> <multilingual-egs-dir>"
  echo "Usage:$0 [opts] 2 exp/lang1/egs exp/lang2/egs exp/multi/egs"
  exit 1;
fi

num_langs=$1

shift 1
args=("$@")
megs_dir=${args[-1]} # multilingual directory
mkdir -p $megs_dir
mkdir -p $megs_dir/info
if [ ${#args[@]} != $[$num_langs+1] ]; then
  echo "$0: num of input example dirs provided is not compatible with num_langs $num_langs."
  echo "Usage:$0 [opts] <num-input-langs,N> <lang1-egs-dir> ...<langN-egs-dir> <multilingual-egs-dir>"
  echo "Usage:$0 [opts] 2 exp/lang1/egs exp/lang2/egs exp/multi/egs"
  exit 1;
fi

num_copies_per_lang=
if [ ! -z "$lang2num_copies" ]; then
  IFS=, read -r -a num_copies_per_lang <<< $lang2num_copies
  if [ ${#num_copies_per_lang[@]} -ne $num_langs ]; then
    echo "$0: --lang2num-copies must be an array of num-langs=$num_langs integers"
    exit 1
  fi
fi

required="${egs_prefix}scp combine.scp train_diagnostic.scp valid_diagnostic.scp"
frames_per_eg_list=
train_scp_list=
train_diagnostic_scp_list=
valid_diagnostic_scp_list=
combine_scp_list=

# read paramter from $egs_dir[0]/info and cmvn_opts
# to write in multilingual egs_dir.
check_params="info/feat_dim info/ivector_dim info/left_context info/right_context info/left_context_initial info/right_context_final cmvn_opts"
ivec_dim=`cat ${args[0]}/info/ivector_dim`
if [ $ivec_dim -ne 0 ];then check_params="$check_params info/final.ie.id"; fi

for param in $check_params; do
  cat ${args[0]}/$param > $megs_dir/$param || exit 1;
done
cat ${args[0]}/cmvn_opts > $megs_dir/cmvn_opts || exit 1; # caution: the top-level nnet training
cp ${args[0]}/info/frames_per_eg $megs_dir/info/frames_per_eg || exit 1;

declare -a multi_egs_dir

for lang in $(seq 0 $[$num_langs-1]);do
  multi_egs_dir[$lang]=${args[$lang]}
  for f in $required; do
    if [ ! -f ${multi_egs_dir[$lang]}/$f ]; then
      echo "$0: no such file ${multi_egs_dir[$lang]}/$f." && exit 1;
    fi
  done

  if [ -z "$lang2num_copies" ] || [ ${num_copies_per_lang[$lang]} -eq 1 ]; then
    train_scp_list="$train_scp_list ${multi_egs_dir[$lang]}/${egs_prefix}scp"
    train_diagnostic_scp_list="$train_diagnostic_scp_list ${multi_egs_dir[$lang]}/train_diagnostic.scp"
    valid_diagnostic_scp_list="$valid_diagnostic_scp_list ${multi_egs_dir[$lang]}/valid_diagnostic.scp"
    combine_scp_list="$combine_scp_list ${multi_egs_dir[$lang]}/combine.scp"
  else
    rm -f $megs_dir/lang${lang}_${egs_prefix}scp $megs_dir/lang${lang}_train_diagnostic.scp \
      $megs_dir/lang${lang}_valid_diagnostic.scp $megs_dir/lang${lang}_combine.scp

    if [ `echo ${num_copies_per_lang[$lang]} | awk "{print int($num_copies_per_lang)}"` != ${num_copies_per_lang[$lang]} ]; then
      echo "$0: Expected --lang2num-copies to have only integers; "
      echo "$0: got ${num_copies_per_lang[$lang]} for language $lang"
      exit 1
    fi

    for i in `seq ${num_copies_per_lang[$lang]}`; do
      awk -v i=$i '{print $1"-"i" "$2}' ${multi_egs_dir[$lang]}/${egs_prefix}scp >> \
        $megs_dir/lang${lang}_${egs_prefix}scp
      awk -v i=$i '{print $1"-"i" "$2}' ${multi_egs_dir[$lang]}/train_diagnostic.scp >> \
        $megs_dir/lang${lang}_train_diagnostic.scp
      awk -v i=$i '{print $1"-"i" "$2}' ${multi_egs_dir[$lang]}/valid_diagnostic.scp >> \
        $megs_dir/lang${lang}_valid_diagnostic.scp
      awk -v i=$i '{print $1"-"i" "$2}' ${multi_egs_dir[$lang]}/combine.scp >> \
        $megs_dir/lang${lang}_combine.scp
    done 

    if [ $(head -n1 $megs_dir/lang${lang}_${egs_prefix}scp | wc -w) -ne 2 ]; then
      echo "$0: Incorrect format in $megs_dir/lang${lang}_${egs_prefix}scp; something went wrong!"
      exit 1
    fi

    train_scp_list="$train_scp_list $megs_dir/lang${lang}_${egs_prefix}scp"
    train_diagnostic_scp_list="$train_diagnostic_scp_list $megs_dir/lang${lang}_train_diagnostic.scp"
    valid_diagnostic_scp_list="$valid_diagnostic_scp_list $megs_dir/lang${lang}_valid_diagnostic.scp"
    combine_scp_list="$combine_scp_list $megs_dir/lang${lang}_combine.scp"
  fi
  
  this_frames_per_eg=$(cat ${args[$lang]}/info/frames_per_eg | \
    awk -F, '{for (i=1; i<=NF; i++) sum += $i;} END{print int(sum / NF)}')  # use average frames-per-eg

  # frames_per_eg_list stores the average frames-per-eg for each language. 
  # The average does not have to be exact.
  if [ $lang -eq 0 ]; then
    frames_per_eg_list="$this_frames_per_eg"
  else
    frames_per_eg_list="$frames_per_eg_list,$this_frames_per_eg"
  fi

  # check parameter dimension to be the same in all egs dirs
  for f in $check_params; do
    if [ -f $megs_dir/$f ] && [ -f ${multi_egs_dir[$lang]}/$f ]; then
      f1=$(cat $megs_dir/$f)
      f2=$(cat ${multi_egs_dir[$lang]}/$f)
      if [ "$f1" != "$f2" ]  ; then
        echo "$0: mismatch for $f in $megs_dir vs. ${multi_egs_dir[$lang]}($f1 vs. $f2)."
        exit 1;
      fi
    else
      echo "$0: file $f does not exits in $megs_dir or ${multi_egs_dir[$lang]}/$f ."
    fi
  done
done

if [ ! -z "$lang2weight" ]; then
  egs_opt="--lang2weight '$lang2weight'"
fi

if [ $stage -le 0 ]; then
  echo "$0: allocating multilingual examples for training."
  # Generate ${egs_prefix}*.scp for multilingual setup.
  $cmd $megs_dir/log/allocate_multilingual_examples_train.log \
  steps/nnet3/multilingual/allocate_multilingual_examples.py $egs_opt \
      ${allocate_opts} --minibatch-size $minibatch_size \
      --frames-per-iter $frames_per_iter --frames-per-eg-list $frames_per_eg_list \
      --egs-prefix "$egs_prefix" \
      $train_scp_list $megs_dir || exit 1;
fi

if [ $stage -le 1 ]; then
  echo "$0: combine combine.scp examples from all langs in $megs_dir/combine.scp."
  # Generate combine.scp for multilingual setup.
  $cmd $megs_dir/log/allocate_multilingual_examples_combine.log \
  steps/nnet3/multilingual/allocate_multilingual_examples.py $egs_opt \
      --random-lang false --max-archives 1 --num-jobs 1 \
      --frames-per-eg-list $frames_per_eg_list \
      ${allocate_opts} --minibatch-size $minibatch_size \
      --egs-prefix "combine." \
      $combine_scp_list $megs_dir || exit 1;

  echo "$0: combine train_diagnostic.scp examples from all langs in $megs_dir/train_diagnostic.scp."
  # Generate train_diagnostic.scp for multilingual setup.
  $cmd $megs_dir/log/allocate_multilingual_examples_train_diagnostic.log \
  steps/nnet3/multilingual/allocate_multilingual_examples.py $egs_opt \
      --random-lang false --max-archives 1 --num-jobs 1 \
      --frames-per-eg-list $frames_per_eg_list \
      ${allocate_opts} --minibatch-size $minibatch_size \
      --egs-prefix "train_diagnostic." \
      $train_diagnostic_scp_list $megs_dir || exit 1;


  echo "$0: combine valid_diagnostic.scp examples from all langs in $megs_dir/valid_diagnostic.scp."
  # Generate valid_diagnostic.scp for multilingual setup.
  $cmd $megs_dir/log/allocate_multilingual_examples_valid_diagnostic.log \
  steps/nnet3/multilingual/allocate_multilingual_examples.py $egs_opt \
      --random-lang false --max-archives 1 --num-jobs 1\
      --frames-per-eg-list $frames_per_eg_list \
      ${allocate_opts} --minibatch-size $minibatch_size \
      --egs-prefix "valid_diagnostic." \
      $valid_diagnostic_scp_list $megs_dir || exit 1;

fi
for egs_type in combine train_diagnostic valid_diagnostic; do
  mv $megs_dir/${egs_type}.output.1.ark $megs_dir/${egs_type}.output.ark || exit 1;
  mv $megs_dir/${egs_type}.weight.1.ark $megs_dir/${egs_type}.weight.ark || exit 1;
  mv $megs_dir/${egs_type}.1.scp $megs_dir/${egs_type}.scp || exit 1;
done
mv $megs_dir/info/${egs_prefix}num_archives $megs_dir/info/num_archives || exit 1;
mv $megs_dir/info/${egs_prefix}num_tasks $megs_dir/info/num_tasks || exit 1;
echo "$0: Finished preparing multilingual training example."
