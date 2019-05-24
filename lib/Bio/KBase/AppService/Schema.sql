SET default_storage_engine=INNODB;
drop table if exists TaskExecution;
drop table if exists ClusterJob;
drop table if exists Cluster;
drop table if exists ClusterType;
drop table if exists TaskToken;
drop table if exists Task;
drop table if exists ServiceUser;
drop table if exists Project;
drop table if exists TaskState;
drop table if exists Application;

CREATE TABLE ClusterType
(
	type VARCHAR(255) PRIMARY KEY
);
INSERT INTO ClusterType VALUES ('AWE'), ('Slurm');

CREATE TABLE Cluster
(
	id varchar(255) PRIMARY KEY,
	type varchar(255),
	name varchar(255),
	account varchar(255),
	remote_host varchar(255),
	remote_user varchar(255),
	remote_keyfile varchar(255),
	scheduler_install_path text,
	temp_path text,
	p3_runtime_path text,
	p3_deployment_path text,
	max_allowed_jobs int,
	FOREIGN KEY (type) REFERENCES ClusterType(type)
) ;
INSERT INTO Cluster (id, type, name, scheduler_install_path, temp_path, p3_runtime_path, p3_deployment_path, 
       remote_host, remote_account, remote_user, remote_keyfile) VALUES 
       ('P3AWE', 'AWE', 'PATRIC AWE Cluster', \N, '/disks/tmp', '/disks/patric-common/runtime', '/disks/p3/deployment', \N, \N, \N, \N),
       ('TSlurm', 'Slurm', 'Test SLURM Cluster', '/disks/patric-common/slurm', '/disks/tmp', 
       		  '/disks/patric-common/runtime', '/home/olson/P3/dev-slurm/dev_container', \N, \N, \N, \N),
       ('Bebop', 'Slurm', 'Bebop', '/usr/bin', '/scratch', '/home/olson/P3/bebop/runtime', '/home/olson/P3/bebop/dev_container',
       		 'bebop.lcrc.anl.gov', 'PATRIC', 'olson', '/homes/olson/P3/dev-slurm/dev_container/bebop.key');


CREATE TABLE TaskState
(
	code VARCHAR(10) PRIMARY KEY,
	description VARCHAR(255),
	service_status VARCHAR(20)
);

INSERT INTO TaskState VALUES
       ('Q', 'Queued', 'queued'),
       ('S', 'Submitted to cluster', 'pending'),
       ('C', 'Completed', 'completed'),
       ('F', 'Failed', 'failed'),
       ('D', 'Deleted', 'deleted'),
       ('T', 'Terminated', 'failed');

CREATE TABLE Application
(
	id VARCHAR(255) PRIMARY KEY,
	script VARCHAR(255),
	spec TEXT,
	default_memory VARCHAR(255),
	default_cpu INTEGER
);

CREATE TABLE Project
(
	id VARCHAR(255) PRIMARY KEY,
	userid_domain VARCHAR(255)
);
INSERT INTO Project VALUES 
       ('PATRIC', 'patricbrc.org'), 
       ('RAST', 'rast.nmpdr.org');

CREATE TABLE ServiceUser
(     
	id VARCHAR(255) PRIMARY KEY,
	project_id VARCHAR(255),
	first_name VARCHAR(255),
	last_name VARCHAR(255),
	email VARCHAR(255),
	affiliation VARCHAR(255),
	FOREIGN KEY (project_id) REFERENCES Project(id)
);

CREATE TABLE Task
(
	id INTEGER AUTO_INCREMENT PRIMARY KEY,
	owner VARCHAR(255),
	parent_task INTEGER,
	state_code VARCHAR(10),
	application_id VARCHAR(255),
	submit_time TIMESTAMP DEFAULT 0,
	start_time TIMESTAMP DEFAULT 0,
	finish_time TIMESTAMP DEFAULT 0,
	monitor_url VARCHAR(255),
	output_path TEXT,
	output_file TEXT,
	params TEXT,
	app_spec TEXT,
	req_memory VARCHAR(255),
	req_cpu INTEGER,
	req_runtime INTEGER,
	req_policy_data TEXT,
	req_is_control_task BOOLEAN,
	FOREIGN KEY (owner) REFERENCES ServiceUser(id),
	FOREIGN KEY (state_code) REFERENCES TaskState(code),
	FOREIGN KEY (application_id) REFERENCES Application(id),
	FOREIGN KEY (parent_task) REFERENCES Task(id)
);

CREATE TABLE ClusterJob
(
	id INTEGER AUTO_INCREMENT PRIMARY KEY,
	task_id INTEGER,
	cluster_id VARCHAR(255),
	job_id VARCHAR(255),
	job_status VARCHAR(255),
	active BOOLEAN,
	maxrss float,
	nodelist TEXT,
	exitcode VARCHAR(255),
	INDEX (job_id),
	FOREIGN KEY(task_id) REFERENCES Task(id),
	FOREIGN KEY(cluster_id) REFERENCES Cluster(id)
) ;

CREATE TABLE TaskToken
(
	task_id INTEGER,
	token TEXT,
	expiration TIMESTAMP DEFAULT 0,
	FOREIGN KEY (task_id) REFERENCES Task(id)
);