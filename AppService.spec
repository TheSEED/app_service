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
    
    typedef structure {
	task_id id;
	app_id app;
	workspace_id workspace;
	task_parameters parameters;
    } Task;

    //    typedef mapping<string stage, string status> task_status;
    typedef string task_status;

    funcdef enumerate_apps()
	returns (list<App>);

    funcdef start_app(app_id, task_parameters params, workspace_id workspace)
	returns (Task task);

    funcdef query_task_status(list<task_id> tasks)
	returns (mapping<task_id, task_status> status);

    funcdef enumerate_tasks()
	returns (list<Task>);
};
