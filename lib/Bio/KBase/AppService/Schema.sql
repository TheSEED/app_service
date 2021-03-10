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

CREATE TABLE Container
(
	id VARCHAR(255) PRIMARY KEY,
	filename VARCHAR(255),	
	creation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE SiteDefaultContainer
(
	base_url VARCHAR(255) PRIMARY KEY,
	default_container_id VARCHAR(255),
	FOREIGN KEY (default_container_id) REFERENCES Container(id)
);

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
	submit_queue varchar(255),
	submit_cluster varchar(255),
	container_repo_url varchar(255),
	container_cache_dir varchar(255),
	default_container_id varchar(255),
	default_data_directory varchar(255),
	FOREIGN KEY (type) REFERENCES ClusterType(type),
	FOREIGN KEY (default_container_id) REFERENCES Container(id)
) ;
INSERT INTO Cluster (id, type, name, scheduler_install_path, temp_path, p3_runtime_path, p3_deployment_path, 
       remote_host, account, remote_user, remote_keyfile) VALUES 
       ('P3AWE', 'AWE', 'PATRIC AWE Cluster', \N, '/disks/tmp', '/disks/patric-common/runtime', '/disks/p3/deployment', \N, \N, \N, \N),
       ('TSlurm', 'Slurm', 'Test SLURM Cluster', '/disks/patric-common/slurm', '/disks/tmp', 
       		  '/disks/patric-common/runtime', '/home/olson/P3/dev-slurm/dev_container', \N, \N, \N, \N),
       ('P3Slurm', 'Slurm', 'P3 SLURM Cluster', '/disks/patric-common/slurm', '/disks/tmp', 
       		  '/disks/patric-common/runtime', '/vol/patric3/production/P3Slurm/deployment', \N, \N, \N, \N),
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
	is_staff BOOLEAN,
	is_collaborator BOOLEAN,
	FOREIGN KEY (project_id) REFERENCES Project(id)
);

CREATE TABLE Task
(
	id INTEGER AUTO_INCREMENT PRIMARY KEY,
	owner VARCHAR(255),
	parent_task INTEGER,
	state_code VARCHAR(10),
	application_id VARCHAR(255),
	submit_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
	start_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
	finish_time TIMESTAMP DEFAULT '1970-01-01 00:00:00',
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
	search_terms text,
	hidden BOOLEAN default FALSE,
	container_id VARCHAR(255),
	base_url VARCHAR(255),
	FOREIGN KEY (owner) REFERENCES ServiceUser(id),
	FOREIGN KEY (state_code) REFERENCES TaskState(code),
	FOREIGN KEY (application_id) REFERENCES Application(id),
	FOREIGN KEY (parent_task) REFERENCES Task(id),
	FOREIGN KEY (container_id) REFERENCES Container(id),
	FULLTEXT KEY search_idx(search_terms)
);

CREATE TABLE loader
(
cluster_job_id varchar(36),
	owner VARCHAR(255),
	state_code VARCHAR(10),
	application_id VARCHAR(255),
	submit_time TIMESTAMP,
	start_time TIMESTAMP ,
	finish_time TIMESTAMP,

	output_path TEXT,
	output_file TEXT,
exit_code varchar(6),
hostname varchar(255),
params text
	);

CREATE TABLE ClusterJob
(
	id INTEGER AUTO_INCREMENT PRIMARY KEY,
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

CREATE TABLE TaskExecution
(
	task_id INTEGER NOT NULL,
	cluster_job_id INTEGER NOT NULL,
	active BOOLEAN NOT NULL,
	index(task_id),
	index(clusteR_job_id),
	FOREIGN KEY (task_id) REFERENCES Task(id);
	FOREIGN KEY (cluster_job_id) REFERENCES ClusterJob(id);
);

CREATE TABLE TaskToken
(
	task_id INTEGER,
	token TEXT,
	expiration TIMESTAMP DEFAULT 0,
	FOREIGN KEY (task_id) REFERENCES Task(id)
);

DROP VIEW TaskWithActiveJob;
CREATE VIEW TaskWithActiveJob AS
SELECT t.*, cj.id as cluster_job_id, cj.cluster_id, cj.job_id as cluster_job, cj.job_status, cj.exitcode,
       cj.nodelist, cj.maxrss, cj.cancel_requested
FROM Task t 
     JOIN TaskExecution te ON t.id = te.task_id
     JOIN ClusterJob cj ON cj.id = te.cluster_job_id
WHERE te.active = 1;

CREATE VIEW MergedTaskStatus AS
SELECT t.id, t.owner, t.state_code, cj.job_status
FROM Task t
     LEFT OUTER JOIN TaskExecution te ON t.id = te.task_id
     LEFT OUTER JOIN ClusterJob cj ON cj.id = te.cluster_job_id
WHERE te.active = 1 OR te.active IS NULL;

DROP VIEW StatsGatherNonCollab;
CREATE VIEW StatsGatherNonCollab AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) AS year, t.application_id, COUNT(t.id) AS job_count
FROM Task t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id NOT IN ('Date', 'Sleep') AND
      u.is_collaborator = 0 AND
      u.is_staff = 0 AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id;

DROP VIEW StatsGatherCollab;
CREATE VIEW StatsGatherCollab AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) as year, 
       CONCAT(t.application_id, '-collab') AS application_id, COUNT(t.id) as job_count
FROM Task t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id IN ('GenomeAssembly', 'GenomeAssembly2', 'GenomeAnnotation') AND
      u.is_collaborator = 1 AND
      u.is_staff = 0 AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id;

CREATE VIEW StatsGather
AS SELECT * FROM StatsGatherCollab UNION SELECT * FROM StatsGatherNonCollab
   ORDER BY year, month, application_id;

DROP VIEW StatsGatherAll;
CREATE VIEW StatsGatherAll AS
SELECT MONTH(t.submit_time) AS month, YEAR(t.submit_time) AS year, t.application_id, COUNT(t.id) AS job_count
FROM Task t JOIN ServiceUser u ON t.owner = u.id
WHERE t.application_id NOT IN ('Date', 'Sleep') AND
      t.state_code = 'C' 
GROUP BY MONTH(t.submit_time), YEAR(t.submit_time), t.application_id
order by YEAR(t.submit_time),MONTH(t.submit_time), t.application_id;
