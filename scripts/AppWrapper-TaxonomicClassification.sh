#!/bin/bash 

#
# Wrapper to invoke the underlying app using p3x-app-shepherd. This 
# should go away after moving to the slurm-based app service.
#

#
# Determine task id.
#

if [[ ! -z ${AWE_TASK_ID+x} ]] ; then
    task_id=$AWE_TASK_ID
elif [[ $PWD =~ ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_[0-9]+_[0-9]+$ ]] ; then
    task_id=${BASH_REMATCH[1]}
else
    host=`hostname`
    task_id="UNK-$host-$$"
fi

#
# Force AWE_TASK_ID to the one computed above, to ensure all is consistent.
#
export AWE_TASK_ID=$task_id

p3x-app-shepherd  --task-id $task_id App-TaxonomicClassification $*