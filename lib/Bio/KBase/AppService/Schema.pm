use utf8;
package Bio::KBase::AppService::Schema;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

use strict;
use warnings;

use base 'DBIx::Class::Schema';

__PACKAGE__->load_namespaces;


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-08-29 13:04:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:X2dxIm3Dd3IdBiORLQB5Ug


# You can replace this text with custom code or comments, and it will be preserved on regeneration

use DateTime;
use JSON::XS;
use 5.010;

my $json = JSON::XS->new->pretty(1)->canonical(1);

sub create_task
{
    my($schema, $token, $app_id, $monitor_url, $task_parameters, $start_parameters, $preflight) = @_;

    my $override_user = $start_parameters->{user_override};

    my $guard = $schema->txn_scope_guard;    

    my $app = $schema->find_app($app_id);
    my $user = $schema->find_user($override_user // $token->user_id, $token);

    #
    # Create our task.
    #

    my $code = $schema->resultset('TaskState')->find({description => 'Queued'}, { result_class => 'DBIx::Class::ResultClass::HashRefInflator' }) ;
    
    my $policy_data;
    
    my $task = $schema->resultset('Task')->create({
	owner => $user->id,
	parent_task => $start_parameters->{parent_id},
	state_code => $code->{code},
	application_id => $app_id,
	submit_time => DateTime->now(),
	params => $json->encode($task_parameters),
	(ref($task_parameters) eq 'HASH' ?
	 (output_path => $task_parameters->{output_path},
	  output_file => $task_parameters->{output_file}) : ()),
	app_spec => $app->spec,
	monitor_url => $monitor_url,
	req_memory => $preflight->{memory},
	req_cpu => $preflight->{cpu},
	req_runtime => $preflight->{runtime},
	req_policy_data => $json->encode($preflight->{policy_data} // {}),
	req_is_control_task => ($preflight->{is_control_task} ? 1 : 0),
    });

    my $tt = $schema->resultset('TaskToken')->create({
	task_id => $task->id,
	token => $token->token,
	expiration => DateTime->from_epoch(epoch => $token->expiry),
    }); 

    say "Created task " . $task->id;

    $guard->commit();
    return $task;
}


sub find_user
{
    my($schema, $userid) = @_;

    my($base, $domain) = split(/\@/, $userid, 2);
    if ($domain eq '')
    {
	$domain = 'rast.nmpdr.org';
	$userid = "$userid\@$domain";
    }
    
    my $urec = $schema->resultset("ServiceUser")->find_or_new({ id => $userid });
    if (!$urec->in_storage)
    {
	my $proj = $schema->resultset("Project")->find({userid_domain => $domain},
						   { result_class => 'DBIx::Class::ResultClass::HashRefInflator' });
	if (!$proj)
	{
	    die "Unknown user domain $domain\n";
	}

	$urec->project_id($proj->{id});
	$urec->insert;
    }

    #
    # We used to have code that used the PATRIC user service to inflate the data.
    # It does not belong here; if we want fuller user data we should have a separate
    # offline thread to manage updates when needed.
    #
    # We also don't try to tell the cluster that there is a new user. When a job
    # is submitted we will get an error that hte usthe user is missing, so we
    # may use that to trigger a fuller update to the both the database and to
    # the cluster user configuration.
    #

    return $urec;
}

=item B<find_app>

Find this app in the database. If it is not there, use the AppSpecs instance
to find the spec file in the filesystem. If that is not there, fail.

    $app = $sched->find_app($app_id)

We return an Application result object.

=cut

sub find_app
{
    my($schema, $app_id, $specs) = @_;

    my $guard = $schema->txn_scope_guard;    

    my $rs = $schema->resultset('Application')->find_or_new({ id => $app_id});
    if ($rs->in_storage)
    {
	$guard->commit();
	return $rs;
    }
    
    if (!$specs)
    {
	die "App $app_id not in database and no specs were passed";
    }
    
    my $app = $specs->find($app_id);
    if (!$app)
    {
	die "Unable to find application '$app_id'";
    }
    
    #
    # Construct our new app record.
    #
    $rs->script($app->{script});
    $rs->default_memory($app->{default_ram});
    $rs->default_cpu($app->{default_cpu});
    $rs->spec($json->encode($app));
    
    $rs->insert();

    $guard->commit();
    return $rs;
}



1;
