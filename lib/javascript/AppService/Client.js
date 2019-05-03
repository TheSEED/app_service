

function AppService(url, auth, auth_cb) {

    this.url = url;
    var _url = url;
    var deprecationWarningSent = false;

    function deprecationWarning() {
        if (!deprecationWarningSent) {
            deprecationWarningSent = true;
            if (!window.console) return;
            console.log(
                "DEPRECATION WARNING: '*_async' method names will be removed",
                "in a future version. Please use the identical methods without",
                "the'_async' suffix.");
        }
    }

    if (typeof(_url) != "string" || _url.length == 0) {
        _url = "http://p3.theseed.org/services/app_service";
    }
    var _auth = auth ? auth : { 'token' : '', 'user_id' : ''};
    var _auth_cb = auth_cb;


    this.service_status = function (_callback, _errorCallback) {
    return json_call_ajax("AppService.service_status",
        [], 1, _callback, _errorCallback);
};

    this.service_status_async = function (_callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.service_status", [], 1, _callback, _error_callback);
    };

    this.enumerate_apps = function (_callback, _errorCallback) {
    return json_call_ajax("AppService.enumerate_apps",
        [], 1, _callback, _errorCallback);
};

    this.enumerate_apps_async = function (_callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.enumerate_apps", [], 1, _callback, _error_callback);
    };

    this.start_app = function (app_id, params, workspace, _callback, _errorCallback) {
    return json_call_ajax("AppService.start_app",
        [app_id, params, workspace], 1, _callback, _errorCallback);
};

    this.start_app_async = function (app_id, params, workspace, _callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.start_app", [app_id, params, workspace], 1, _callback, _error_callback);
    };

    this.start_app2 = function (app_id, params, start_params, _callback, _errorCallback) {
    return json_call_ajax("AppService.start_app2",
        [app_id, params, start_params], 1, _callback, _errorCallback);
};

    this.start_app2_async = function (app_id, params, start_params, _callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.start_app2", [app_id, params, start_params], 1, _callback, _error_callback);
    };

    this.query_tasks = function (task_ids, _callback, _errorCallback) {
    return json_call_ajax("AppService.query_tasks",
        [task_ids], 1, _callback, _errorCallback);
};

    this.query_tasks_async = function (task_ids, _callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.query_tasks", [task_ids], 1, _callback, _error_callback);
    };

    this.query_task_summary = function (_callback, _errorCallback) {
    return json_call_ajax("AppService.query_task_summary",
        [], 1, _callback, _errorCallback);
};

    this.query_task_summary_async = function (_callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.query_task_summary", [], 1, _callback, _error_callback);
    };

    this.query_task_details = function (task_id, _callback, _errorCallback) {
    return json_call_ajax("AppService.query_task_details",
        [task_id], 1, _callback, _errorCallback);
};

    this.query_task_details_async = function (task_id, _callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.query_task_details", [task_id], 1, _callback, _error_callback);
    };

    this.enumerate_tasks = function (offset, count, _callback, _errorCallback) {
    return json_call_ajax("AppService.enumerate_tasks",
        [offset, count], 1, _callback, _errorCallback);
};

    this.enumerate_tasks_async = function (offset, count, _callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.enumerate_tasks", [offset, count], 1, _callback, _error_callback);
    };

    this.kill_task = function (id, _callback, _errorCallback) {
    return json_call_ajax("AppService.kill_task",
        [id], 2, _callback, _errorCallback);
};

    this.kill_task_async = function (id, _callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.kill_task", [id], 2, _callback, _error_callback);
    };

    this.rerun_task = function (id, _callback, _errorCallback) {
    return json_call_ajax("AppService.rerun_task",
        [id], 1, _callback, _errorCallback);
};

    this.rerun_task_async = function (id, _callback, _error_callback) {
        deprecationWarning();
        return json_call_ajax("AppService.rerun_task", [id], 1, _callback, _error_callback);
    };
 

    /*
     * JSON call using jQuery method.
     */
    function json_call_ajax(method, params, numRets, callback, errorCallback) {
        var deferred = $.Deferred();

        if (typeof callback === 'function') {
           deferred.done(callback);
        }

        if (typeof errorCallback === 'function') {
           deferred.fail(errorCallback);
        }

        var rpc = {
            params : params,
            method : method,
            version: "1.1",
            id: String(Math.random()).slice(2),
        };

        var beforeSend = null;
        var token = (_auth_cb && typeof _auth_cb === 'function') ? _auth_cb()
            : (_auth.token ? _auth.token : null);
        if (token != null) {
            beforeSend = function (xhr) {
                xhr.setRequestHeader("Authorization", token);
            }
        }

        var xhr = jQuery.ajax({
            url: _url,
            dataType: "text",
            type: 'POST',
            processData: false,
            data: JSON.stringify(rpc),
            beforeSend: beforeSend,
            success: function (data, status, xhr) {
                var result;
                try {
                    var resp = JSON.parse(data);
                    result = (numRets === 1 ? resp.result[0] : resp.result);
                } catch (err) {
                    deferred.reject({
                        status: 503,
                        error: err,
                        url: _url,
                        resp: data
                    });
                    return;
                }
                deferred.resolve(result);
            },
            error: function (xhr, textStatus, errorThrown) {
                var error;
                if (xhr.responseText) {
                    try {
                        var resp = JSON.parse(xhr.responseText);
                        error = resp.error;
                    } catch (err) { // Not JSON
                        error = "Unknown error - " + xhr.responseText;
                    }
                } else {
                    error = "Unknown Error";
                }
                deferred.reject({
                    status: 500,
                    error: error
                });
            }
        });

        var promise = deferred.promise();
        promise.xhr = xhr;
        return promise;
    }
}


