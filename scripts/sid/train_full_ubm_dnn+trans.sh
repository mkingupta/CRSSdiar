#!/bin/bash
# Copyright 2015   David Snyder
#           2015   Johns Hopkins University (Author: Daniel Garcia-Romero)
#           2015   Johns Hopkins University (Author: Daniel Povey)
# Apache 2.0

# This script derives a full-covariance UBM from DNN posteriors and
# speaker recognition features.

# Begin configuration section.
nj=40
cmd="run.pl"
stage=-2
delta_window=3
delta_order=2
# End configuration section.

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# != 6 ]; then
  echo "Usage: steps/init_full_ubm_from_dnn.sh <data-speaker-id> <data-dnn> <dnn-model> <new-ubm-dir>"
  echo "Initializes a full-covariance UBM from DNN posteriors and speaker recognition features."
  echo " e.g.: steps/init_full_ubm_from_dnn.sh data/train data/train_dnn exp/dnn/final.mdl exp/full_ubm"
  echo "main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --nj <n|16>                                      # number of parallel training jobs"
  echo "  --delta-window <n|3>                             # delta window size"
  echo "  --delta-order <n|2>                              # delta order"
  echo "                                                   # to be equal to the size of the DNN output layer."
  exit 1;
fi

data=$1
data_dnn=$2
dnndir=$3
dir=$4
alidir=$5
scale=$6

#for f in $data/feats.scp $data/vad.scp ${data_dnn}/feats.scp \
#    ${data_dnn}/vad.scp $nnet; do
#  [ ! -f $f ] && echo "No such file $f" && exit 1;
#done

mkdir -p $dir/log
echo $nj > $dir/num_jobs
sdata=$data/split$nj;
utils/split_data.sh $data $nj || exit 1;

sdata_dnn=$data_dnn/split$nj;
utils/split_data.sh $data_dnn $nj || exit 1;

delta_opts="--delta-window=$delta_window --delta-order=$delta_order"
echo $delta_opts > $dir/delta_opts

logdir=$dir/log

nnet_feats="ark,s,cs:add-deltas $delta_opts scp:$sdata_dnn/JOB/feats.scp ark:-| apply-cmvn-sliding --norm-vars=true --center=true --cmn-window=300 ark:- ark:- |"

#feats="ark,s,cs:add-deltas $delta_opts scp:$sdata/JOB/feats.scp ark:- | \
#apply-cmvn-sliding --norm-vars=false --center=true --cmn-window=300 ark:- ark:- | \
#select-voiced-frames ark:- scp,s,cs:$sdata/JOB/vad.scp ark:- |"

feats="ark,s,cs:add-deltas $delta_opts scp:$sdata/JOB/feats.scp ark:- | apply-cmvn-sliding --norm-vars=false --center=true --cmn-window=300 ark:- ark:- |" 

# Parse the output of nnet-am-info to find the size of the output layer
# of the TDNN.  This will also correspond to the number of components
# in the ancillary GMM.
#num_components=`grep -oP 'output-dim\ \K[0-9]+' <(nnet-am-info $nnet 2> /dev/null)`
num_components=`grep -oP -m 1 'output-dim\ \K[0-9]+' <(nnet-info $dnndir/final.nnet 2> /dev/null) | head -1`

#$cmd JOB=1:$nj $logdir/make_stats.JOB.log \
#  nnet-am-compute --apply-log=true $nnet "$nnet_feats" ark:- \
#  \| select-voiced-frames ark:- scp,s,cs:$sdata/JOB/vad.scp ark:- \
#  \| logprob-to-post ark:- ark:- \| \
#  fgmm-global-acc-stats-post ark:- $num_components "$feats" \
#  $dir/stats.JOB.acc || exit 1;

alignments="ark,s,cs:ali-to-pdf $alidir/final.mdl \"ark:gunzip -c $alidir/ali.JOB.gz|\"  ark:- |"

$cmd JOB=1:$nj $logdir/make_stats.JOB.log \
  nnet-forward --apply-log=true --prior-scale=1.0 --feature-transform=$dnndir/final.feature_transform $dnndir/final.nnet scp:$sdata_dnn/JOB/feats.scp ark:- \
  \| logprob-to-post --min-post=0 ark:- ark:- \
  \| post-ali-wsum-thr  ark:- "$alignments" $scale ark:- \| \
  fgmm-global-acc-stats-post ark:- $num_components "$feats" $dir/stats.JOB.acc || exit 1; 

#$cmd JOB=1:$nj $logdir/make_post.JOB.log \
#    nnet-forward --apply-log=true --prior-scale=1.0 --feature-transform=$dnndir/final.feature_transform $dnndir/final.nnet "$nnet_feats" ark:- | logprob-to-post ark:- ark:$dir/posts.JOB || exit
#
#$cmd JOB=1:$nj $logdir/make_stats.JOB.log \
#    fgmm-global-acc-stats-post ark:$dir/posts.JOB $num_components "$feats" \
#    $dir/stats.JOB.acc || exit 1;  

$cmd $dir/log/init.log \
  fgmm-global-init-from-accs --verbose=2 \
  "fgmm-global-sum-accs - $dir/stats.*.acc |" $num_components \
  $dir/final.ubm || exit 1;

exit 0;
