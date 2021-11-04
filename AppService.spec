module AppService
{
    authentication required;
    
    typedef string task_id;
    typedef string app_id;
    typedef string workspace_id;

    typedef mapping<string, string> task_parameters;

    typedef structure {
	string id;
	string label;
	int required;
	string default;
	string desc;
	string type;
	string enum;
	string wstype;
    } AppParameter;

    typedef structure {
	app_id id;
	string script;
	string label;
	string description;
	list<AppParameter> parameters;
    } App;
    
    typedef string task_status;

    typedef structure {
	task_id id;
	task_id parent_id;
	app_id app;
	workspace_id workspace;
	task_parameters parameters;
	string user_id;

	task_status status;
	task_status awe_status;
	string submit_time;
	string start_time;
	string completed_time;
	string elapsed_time;

	string stdout_shock_node;
	string stderr_shock_node;

    } Task;

    typedef structure {
	task_id id;
	App app;
	task_parameters parameters;
	float start_time;
	float end_time;
	float elapsed_time;
	string hostname;
	list <tuple<string output_path, string output_id>> output_files;
    } TaskResult;

    funcdef service_status() returns (tuple<int submission_enabled, string status_message>);

    funcdef enumerate_apps()
	returns (list<App>);

    funcdef start_app(app_id, task_parameters params, workspace_id workspace)
	returns (Task task);

    typedef structure {
        task_id parent_id;
	workspace_id workspace;
	string base_url;
	string container_id;
	string user_metaata;
	string reservation;
	string data_container_id;
    } StartParams;
    funcdef start_app2(app_id, task_parameters params, StartParams start_params)
	returns (Task task);

    funcdef query_tasks(list<task_id> task_ids)
	returns (mapping<task_id, Task task> tasks);

    funcdef query_task_summary() returns (mapping<task_status status, int count> status);

    funcdef query_app_summary() returns (mapping<app_id app, int count> status);

    typedef structure {
	string stdout_url;
	string stderr_url;
	int pid;
	string hostname;
	int exitcode;
    } TaskDetails;
    funcdef query_task_details(task_id) returns (TaskDetails details);

    funcdef enumerate_tasks(int offset, int count)
	returns (list<Task>);

    typedef structure {
 	string start_time;
	string end_time;
	app_id app;
	string search;
	string status;
    } SimpleTaskFilter;
    funcdef enumerate_tasks_filtered(int offset, int count, SimpleTaskFilter simple_filter)
	returns (list<Task> tasks, int total_tasks);

    funcdef kill_task(task_id id) returns (int killed, string msg);
    funcdef kill_tasks(list<task_id> ids) returns (mapping<task_id, structure { int killed; string msg; }>);
    funcdef rerun_task(task_id id) returns (Task task);
};
