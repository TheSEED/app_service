SET default_storage_engine=INNODB;
drop table if exists ClusterJob;
drop table if exists Cluster;
drop table if exists ClusterType;
drop table if exists TaskToken;
drop table if exists Task;
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
	FOREIGN KEY (type) REFERENCES ClusterType(type)
) ;
INSERT INTO Cluster VALUES 
       ('P3AWE', 'AWE', 'PATRIC AWE Cluster'),
       ('TSlurm', 'Slurm', 'Test SLURM Cluster');

CREATE TABLE ClusterJob
(
	id INTEGER AUTO_INCREMENT PRIMARY KEY,
	task_id INTEGER,
	cluster_id VARCHAR(255),
	job_id VARCHAR(255),
	INDEX (job_id),
	FOREIGN KEY(cluster_id) REFERENCES Cluster(id)
) ;

CREATE TABLE TaskState
(
	code VARCHAR(10) PRIMARY KEY,
	description VARCHAR(255)
);

INSERT INTO TaskState VALUES
       ('Q', 'Queued'),
       ('S', 'Submitted'),
       ('QC', 'Queued on cluster'),
       ('R', 'Running'),
       ('C', 'Completed'),
       ('F', 'Failed'),
       ('D', 'Deleted');

CREATE TABLE Application
(
	id VARCHAR(255) PRIMARY KEY,
	script VARCHAR(255),
	default_memory INTEGER,
	default_cpu INTEGER
);

CREATE TABLE Task
(
	id INTEGER AUTO_INCREMENT PRIMARY KEY,
	parent_task INTEGER,
	state_code VARCHAR(10),
	application_id VARCHAR(255),
	username VARCHAR(255),
	submit_time TIMESTAMP DEFAULT 0,
	start_time TIMESTAMP DEFAULT 0,
	finish_time TIMESTAMP DEFAULT 0,
	params TEXT,
	app_spec TEXT,
	FOREIGN KEY (state_code) REFERENCES TaskState(code),
	FOREIGN KEY (application_id) REFERENCES Application(id),
	FOREIGN KEY (parent_task) REFERENCES Task(id)
);

CREATE TABLE TaskToken
(
	task_id INTEGER PRIMARY KEY,
	token TEXT,
	expiration TIMESTAMP DEFAULT 0,
	FOREIGN KEY (task_id) REFERENCES Task(id)
);