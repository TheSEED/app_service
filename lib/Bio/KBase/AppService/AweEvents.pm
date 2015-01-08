
package Bio::KBase::AppService::AweEvents;
use strict;

our %events = (
CR => ['CLIENT_REGISTRATION', 'client registered (for the first time)'],
CA => ['CLIENT_AUTO_REREGI', 'client automatically re-registered'],
CU => ['CLIENT_UNREGISTER', 'client unregistered'],
WC => ['WORK_CHECKOUT', 'workunit checkout'],
WF => ['WORK_FAIL', 'workunit fails running'],
SS => ['SERVER_START', 'awe-server start'],
SR => ['SERVER_RECOVER', 'awe-server start with recover option  (-recover)'],
JQ => ['JOB_SUBMISSION', 'job submitted'],
TQ => ['TASK_ENQUEUE', 'task parsed and enqueue'],
WD => ['WORK_DONE', 'workunit received successful feedback from client'],
WR => ['WORK_REQUEUE', 'workunit requeue after receive failed feedback from client'],
WP => ['WORK_SUSPEND', 'workunit suspend after failing for conf.Max_Failure times'],
TD => ['TASK_DONE', 'task done (all the workunits in the task have finished)'],
TS => ['TASK_SKIPPED', 'task skipped (skip option > 0)'],
JD => ['JOB_DONE', 'job done (all the tasks in the job have finished)'],
JP => ['JOB_SUSPEND', 'job suspended'],
JL => ['JOB_DELETED', 'job deleted'],
WS => ['WORK_START', 'workunit command start running'],
WE => ['WORK_END', 'workunit command finish running'],
WR => ['WORK_RETURN', 'send back failed workunit to server'],
WI => ['WORK_DISCARD', 'workunit discarded after receiving discard signal from server'],
PS => ['PRE_WORK_START', 'workunit command start running'],
PE => ['PRE_WORK_END', 'workunit command finish running'],
FI => ['FILE_IN', 'start fetching input file from shock'],
FR => ['FILE_READY', 'finish fetching input file from shock'],
FO => ['FILE_OUT', 'start pushing output file to shock'],
FD => ['FILE_DONE', 'finish pushing output file to shock'],
AI => ['ATTR_IN', 'start fetching input attributes from shock'],
AR => ['ATTR_READY', 'finish fetching input attributes from shock'],
WQ => ['WORK_QUEUED', 'workunit queued at proxy'],
);
1;
