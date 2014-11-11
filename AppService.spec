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
	app_id app;
	workspace_id workspace;
	task_parameters parameters;

	task_status status;
	string submit_time;
	string start_time;
	string completed_time;
    } Task;

    funcdef enumerate_apps()
	returns (list<App>);

    funcdef start_app(app_id, task_parameters params, workspace_id workspace)
	returns (Task task);

    funcdef query_tasks(list<task_id> task_ids)
	returns (mapping<task_id, Task task> tasks);

    funcdef query_task_summary() returns (mapping<task_status status, int count> status);

    funcdef enumerate_tasks(int offset, int count)
	returns (list<Task>);
};
