Starting the service:

env KB_DEPLOYMENT_CONFIG=holly.cfg plackup  --access-log /dev/tty lib/AppServiceAsync.psgi





Need to calculate process-start offset based on process start time and the calculation start time from /proc/stat.


App client logic:

Remember this is a single-thread fully asynchronous app. No blocking. Everything is
callback-based. Think about using std::future but that is a project for another day.

Maintain a queue of pending blocks to be written to the app service.
Maintain a current state of the app service connection: Disabled, Live, InProgress, Dead

	 Disabled means the client has not been configured with a valid URL
	 or otherwise cannot operate. 
	 InProgress means a request is in process
	 Live means the last time we tried to write, it worked (also initial state)
	 Dead means the last time we tried to write, it failed

Maintain additional states of last_success_time and n_failed_attempts. 

On a write_block operation, we enqueue the block, and then run process_queue();

process_queue():
	
	if IN_PROGRESS
	   return

	if queue is not empty 
	      ent = queue.head
	      if (LIVE)
	      	  set status to IN_PROGRESS
	      	  write_block(ent, on-success, on-failure)

on-sucess(ent):
	Verify head of queue is same buffer as ent. If not, scream (and leave the queue qlone)
	Pop head of queue.
	set status to LIVE
	set n_failures = 0
	dispatch process_queue()

on-failure(ent):
	Leave queue alone.
	if status == DEAD:
	   increment n_failures
	else
	   set status to DEAD and set n_failures = 1
	set timer for retry to dispatch process_queue()


