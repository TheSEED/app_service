package Bio::KBase::AppService::Github;
use Bio::KBase::AppService::AppConfig;

use strict;
use LWP::UserAgent;
use Data::Dumper;

sub submit_github_issue
{
    my($rc, $rest, $task_id, $args) = @_;

    my($stdout, $stderr);

    $rest->GET('/stdout');
    if ($rest->responseCode != 200)
    {
	warn "Failure returning stdout: " . $rest->responseContent . "\n";
    }
    else
    {
	$stdout = $rest->responseContent;
    }
	
    $rest->GET('/stderr');
    if ($rest->responseCode != 200)
    {
	warn "Failure returning stderr: " . $rest->responseContent . "\n";
    }
    else
    {
	$stderr = $rest->responseContent;
    }

    my $app_def_file = $args->[0];
    my $params_file = $args->[1];
    my $app_def = $json->decode(scalar read_file($app_def_file));
    my $params =  $json->decode(scalar read_file($params_file));
    
}

1;
