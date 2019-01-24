#!/usr/bin/env bash
#########################################################################################################################################
###                                                                                                                                   ###
###  Script that can be added to crontab of any caffe based image to allow training to be executed on spot instances                  ###
###                                                                                                                                   ###
###                                                                                                                                   ###
###  Authors:                                                                                                                         ###
###     - Paulo Miguel Almeida <paulo@zag.team>                                                                                       ###
###                                                                                                                                   ###
###  Manual installation steps:                                                                                                       ###
###     root# LOG_FILE=/var/log/train.log                                                                                             ###
###     root# SCRIPT=/opt/automation/train.sh                                                                                         ###
###     root# TRAIN_DIR=/home/ubuntu/workspace/MobileNet-SSD                                                                          ###
###     root# SOLVER_FILE="$TRAIN_DIR/solver_train.prototxt"                                                                          ###
###     root# SYNC_S3=s3://poc-ratatouille-models/object-detection/                                                                   ###
###                                                                                                                                   ###
###     root# touch $LOG_FILE                                                                                                         ###
###     root# chmod 666 $LOG_FILE                                                                                                     ###
###     root# mkdir -p $(dirname $SCRIPT)                                                                                             ###
###     root# wget -O /tmp/train.sh URL_Marota                                                                                        ###
###     root# mv /tmp/train.sh $SCRIPT                                                                                                ###
###     root# chmod +x $SCRIPT                                                                                                        ###
###     root# (crontab -l ; echo "*/10 * * * * $SCRIPT $TRAIN_DIR $SOLVER_FILE $SYNC_S3 $LOG_FILE 2>&1 >> $LOG_FILE &") | crontab -   ###                                                                                                         ###
#########################################################################################################################################

# Add any other path that you judge necessary
export PATH=/usr/local/bin:/opt/movidius/caffe/build/tools/:$PATH

# Global variables
TRAINING_ROOT_DIR="$1"
SOLVER_PROTO_FILE="$2"
S3_BUCKET_KEY="$3"
LOG_FILE="$4"

# Global functions
function get_most_recent_caffe_training_file()
{
    local TARGET_DIR=$1
    local EXTENSION=$2
    local RESULT=""

    local ESCAPED_TARGET_DIR=$(echo "$TARGET_DIR" | sed -e 's/[\/&]/\\&/g')

    if ls -1 $TARGET_DIR*$EXTENSION > /dev/null; then
      echo $RESULT
    else
      echo $(ls -1 $TARGET_DIR*$EXTENSION | sed -e "s/$ESCAPED_TARGET_DIR//g" | sed 's/[^0-9]*//g' | sort -gr | head -1 | sed -e "s/^/$ESCAPED_TARGET_DIR/g" | sed -e "s/$/$EXTENSION/g")
    fi
}

# Flow variables
WEIGHTS_SNAPSHOT_PREFIX_DIR="$TRAINING_ROOT_DIR/$(cat $SOLVER_PROTO_FILE  | grep "snapshot_prefix:" | awk '{print $2}' | sed -e 's/\"//g')_iter_"

# Weight files synchronization
echo "aws s3 sync $S3_BUCKET_KEY $(dirname $WEIGHTS_SNAPSHOT_PREFIX_DIR)/"
aws s3 sync $S3_BUCKET_KEY $(dirname $WEIGHTS_SNAPSHOT_PREFIX_DIR)/ 2>&1 >> $LOG_FILE
echo "aws s3 sync $(dirname $WEIGHTS_SNAPSHOT_PREFIX_DIR)/ $S3_BUCKET_KEY"
aws s3 sync $(dirname $WEIGHTS_SNAPSHOT_PREFIX_DIR)/ $S3_BUCKET_KEY 2>&1 >> $LOG_FILE

# Start the training if needed
if [[ "$(pidof caffe)" ]]
then
    echo "Process is already running...nothing to do here"
else
    # Tries to infer native/attached GPUs on the EC2 instance
    N_GPU=$(nvidia-smi -q | grep "Attached GPUs" | awk '{print $4}')
    if [[ -z "$N_GPU" ]]
    then
        GPU_STMT=""
    else
        N_GPU=$((N_GPU - 1))
        if (( N_GPU == 0 )) ; then
            GPU_STMT="-gpu 0"
        else
            GPU_STMT="-gpu $(seq -s, 0 $N_GPU)"
        fi
    fi

    # Figure out whether this the continuation of a training or a brand new one
    # The precedence is defined as such
    # - *.solverstate - for resuming the previous training process
    # - *.caffemodel - for starting a "brand-new" transfer-learning process
    # - None of the above - for starting a training from scratch

    MOST_RECENT_WEIGHTS_FILE=$(get_most_recent_caffe_training_file $WEIGHTS_SNAPSHOT_PREFIX_DIR ".solverstate")
    if [[ -z "$MOST_RECENT_WEIGHTS_FILE" ]]
    then
        MOST_RECENT_WEIGHTS_FILE=$(get_most_recent_caffe_training_file $WEIGHTS_SNAPSHOT_PREFIX_DIR ".caffemodel")
        if [[ -z "$MOST_RECENT_WEIGHTS_FILE" ]]
        then
            TRAIN_SUFFIX_STMT=""
        else
            TRAIN_SUFFIX_STMT="--weights $MOST_RECENT_WEIGHTS_FILE"
        fi
    else
        TRAIN_SUFFIX_STMT="-snapshot $MOST_RECENT_WEIGHTS_FILE"
    fi

    cd $TRAINING_ROOT_DIR
    caffe train -solver=$SOLVER_PROTO_FILE $TRAIN_SUFFIX_STMT $GPU_STMT 2>&1 | tee $LOG_FILE
fi
