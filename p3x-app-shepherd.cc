/*
 * PATRIC application execution shepherd
 *
 * Usage:
 *
 * p3x-app-shepherd --app-service URL --stdout-file stdout.txt --stderr-file stderr.txt \
 *     command param param ...
 */

#include <boost/filesystem.hpp>
#include <boost/program_options.hpp>
#include <boost/process.hpp>
#include <boost/asio.hpp>
#include <boost/bind.hpp>
#include <boost/format.hpp>

#include <iostream>
#include <fstream>
#include <istream>
#include <ostream>
#include <string>
#include <vector>
#include <memory>

#include <unistd.h>
#include <netdb.h>

#include "pidinfo.h"
#include "app_client.h"
#include "buffer.h"

namespace fs = boost::filesystem;
namespace po = boost::program_options;
namespace bp = boost::process;

class AppOptions
{
public:
    std::string app_name;
    po::variables_map vm;
    po::options_description desc;

    std::string app_service_url;
    std::string task_id;
    fs::path stdout_file;
    fs::path stderr_file;
    std::string command;
    std::vector<std::string> parameters;

    int measurement_interval;

    void parse(int argc, char *argv[]);
    void usage(std::ostream &os);
};

void AppOptions::usage(std::ostream &os)
{
    os << "Usage: " << app_name << " [options] command [param ...]\nAllowed options:\n";
    os << desc;
}

void AppOptions::parse(int argc, char *argv[])
{
    app_name = argv[0];

    std::string sout, serr;
    desc.add_options()
	("help,h", "show this help message")
	("app-service", po::value<std::string>(&app_service_url), "Application service URL")
	("task-id", po::value<std::string>(&task_id), "Task ID")
	("stdout-file", po::value<std::string>(&sout), "File to which standard output is to be written")
	("stderr-file", po::value<std::string>(&serr), "File to which standard error is to be written")
	("measurement-interval", po::value<int>(&measurement_interval)->default_value(10), "Resource measurement interval")
	;

    po::options_description hidden;
    hidden.add_options()
	("command", po::value<std::string>(&command))
	("parameters", po::value<std::vector<std::string> >(&parameters), "Command parameters")
	;

    po::positional_options_description pd;
    pd.add("command", 1);
    pd.add("parameters", -1);

    po::options_description cmdline_options;
    cmdline_options.add(desc).add(hidden);
    
    po::store(po::command_line_parser(argc, argv).
	      options(cmdline_options).positional(pd).run(), vm);
    
    po::store(po::parse_command_line(argc, argv, desc), vm);
    
    if (vm.count("help"))
    {
	usage(std::cout);
	exit(0);
    }

    po::notify(vm);
	
    stdout_file = sout;
    stderr_file = serr;

    if (command.empty())
    {
	usage(std::cout);
	exit(0);
    }

    std::cout << "command: " << command << std::endl;
    for (auto p : parameters)
    {
	std::cout << p << std::endl;
    }
}

class ExecutionManager
{
public:
    ExecutionManager(const AppOptions &opt, boost::asio::io_service &ios) :
	opt_(opt),
	measurement_timer_(ios),
	ios_(ios),
	app_client_(std::make_shared<AppClient>(ios, opt.app_service_url, opt.task_id)),
	stdout_pipe_(ios),
	stderr_pipe_(ios),
	fifo_desc_(ios),
	pipes_waiting_(2),
	exiting_(false) {
    }

    ~ExecutionManager() {
	fs::remove(fifo_path_);
    }

    void validate_command() {
	if (opt_.command.find('/') != std::string::npos)
	{
	    cmd_path_ = opt_.command;
	}
	else
	{
	    cmd_path_ = bp::search_path(opt_.command);
	}
    
	if (cmd_path_.empty())
	{
	    std::cerr << "cannot find command " << opt_.command << " in PATH:" << std::endl;
	    for (auto x:  ::boost::this_process::path())
		std::cerr << "\t" << x << std::endl;
	    exit(1);
	}
	// std::cerr << "found command: " << cmd_path_ << std::endl;
    }

    void handle_measurement(const boost::system::error_code& e) {
	if (e == boost::asio::error::operation_aborted)
	{
	    // std::cerr << "timer aborted\n";
	    return;
	}

	std::cout << "tick\n";
	measure_child();
	
	if (pipes_waiting_ > 0)
	{
	    measurement_timer_.expires_from_now(boost::posix_time::seconds(opt_.measurement_interval));
	    measurement_timer_.async_wait(boost::bind(&ExecutionManager::handle_measurement,
						      this,
						      boost::asio::placeholders::error));
	}
    }

    /*
     * Invoked when the child process completes.
     */
    void child_complete() {

	/*
	 * Do a wait to get child status and so that rusage_children returns appropriate data.
	 *
	 * We should loop here because elsewhere we detected child completeness by the stdout/stderr
	 * pipes being closed; it's possible that they were closed but the process continues;
	 */

	child_.wait();
	int rc = child_.exit_code();
	std::cout << "exit code=" << rc << std::endl;
	app_client_->write_block("exitcode", std::to_string(rc) + "\n", true);
	
	auto now = p3_clock::now();
	struct rusage ru;
	if (getrusage(RUSAGE_CHILDREN, &ru) < 0)
	    std::cerr << "getrusage failed: " << strerror(errno) << std::endl;
	else
	{
	    double utime = (double) ru.ru_utime.tv_sec + ((double) ru.ru_utime.tv_usec) * 1e-6;
	    double stime = (double) ru.ru_stime.tv_sec + ((double) ru.ru_stime.tv_usec) * 1e-6;
	    std::cerr << "   utime=" << utime << " stime=" << stime << std::endl;
	    app_client_->write_block("dynamic_utilization",
				     str(boost::format("%1$f\t%2%\t%3%\n")
					 % (1e-6 * (double) std::chrono::duration_cast<std::chrono::microseconds>(now.time_since_epoch()).count())
					 % utime
					 % stime));
	}

	double utime = 0.0;
	double stime = 0.0;
	std::cerr << "process history\n";

	for (auto x: history_.status())
	{
	    auto pid = x.first;
	    auto &info = x.second;
	    std::cerr << info << std::endl;
	    app_client_->write_block("runtime_summary", str(boost::format("%1%\n") % info));
	    utime += info.utime();
	    stime += info.stime();
	}
	std::cerr << "aggregate utime=" << utime << " stime=" << stime << std::endl;
	app_client_->write_block("runtime_summary", str(boost::format("aggregate utime=%1% stime=%2%\n") % utime % stime));
    }
	

    void measure_child() {

	double utime = 0.0, stime = 0.0;
	history_.check();
	history_.get_cumulative_times(utime, stime);
	std::cerr << "check: " << utime << " " << stime << std::endl;
	auto now = p3_clock::now();
	app_client_->write_block("dynamic_utilization",
				 str(boost::format("%1$f\t%2%\t%3%\n")
				     % (1e-6 * (double) std::chrono::duration_cast<std::chrono::microseconds>(now.time_since_epoch()).count())
				     % utime
				     % stime));
	
	/*

	struct rusage ru;
	if (getrusage(RUSAGE_CHILDREN, &ru) < 0)
	    std::cerr << "getrusage failed: " << strerror(errno) << std::endl;
	else
	{
	    double utime = (double) ru.ru_utime.tv_sec + ((double) ru.ru_utime.tv_usec) * 1e-6;
	    double stime = (double) ru.ru_stime.tv_sec + ((double) ru.ru_stime.tv_usec) * 1e-6;
	    std::cerr << "   utime=" << utime << " stime=" << stime << std::endl;
	}

	*/
    }

    void handle_data(const boost::system::error_code &ec, std::size_t size,
		     bp::async_pipe &pipe,
		     std::shared_ptr<OutputBuffer> buf) {
	// std::cout << buf->key() << " read of size " << size << " ec=" << ec << std::endl;
	
	if (size > 0)
	{
	    buf->size(size);
	    app_client_->write_block(buf);
	    
	    // std::cout << buf->as_string() << std::endl;
	}
	
	if (ec == boost::asio::error::eof)
	{
	    // std::cout << "done reading " << buf->key() << std::endl;
	    app_client_->write_block(buf->key() + ".EOF", "");
	    pipes_waiting_--;
	    pipe.close();

	    // Check for child having finished.
	    if (pipes_waiting_ == 0)
	    {
		std::cerr << "Child is finished\n";
		exiting_ = true;
		measurement_timer_.cancel();
		fifo_desc_.cancel();
		child_complete();
	    }
	}
	else
	{
	    auto new_buf = std::make_shared<OutputBuffer>(buf->key());
	    pipe.async_read_some(boost::asio::buffer(new_buf->data(), new_buf->capacity()),
				 boost::bind(&ExecutionManager::handle_data,
					     this,
					     boost::asio::placeholders::error,
					     boost::asio::placeholders::bytes_transferred,
					     boost::ref(pipe),
					     new_buf));
	}
    }

    void handle_fifo_data(const boost::system::error_code &ec, std::size_t size,
			  boost::asio::posix::stream_descriptor &pipe,
			  std::shared_ptr<OutputBuffer> buf) {
	if (ec == boost::asio::error::operation_aborted)
	{
	    //std::cerr << "handle_fifo_data aborted\n";
	    return;
	}

	// std::cout << buf->key() << " read of size " << size << " ec=" << ec << std::endl;
	buf->size(size);

	
	if (size > 0)
	{
	    std::string data(buf->as_string(size));

	    std::vector<std::string> lines, params;
	    boost::split(lines, data, [](char c) { return c == '\n'; });
	    std::string progname, cmd, statline;
	    pid_t pid = 0;
	    auto viter = lines.begin();
	    std::string what = *viter++;
	    double utime = 0.0, stime = 0.0;
	    
	    if (what == "execve")
	    {
		pid = std::stoul(*viter++);
		progname = *viter++;
		cmd = *viter++;
		std::copy(viter, lines.end(), std::back_inserter(params));
		history_.pid_new(pid, cmd, params);
	    }
	    else if (what == "START")
	    {
		pid = std::stoul(*viter++);
		viter++;
		cmd = *viter++;
		std::copy(viter, lines.end(), std::back_inserter(params));
		history_.pid_new(pid, cmd, params);
	    }
	    else if (what == "exit" || what == "done")
	    {
		timeval ru_utime, ru_stime;
		pid = std::stoul(*viter++);
		statline = *viter++;
		ru_utime.tv_sec = std::stoul(*viter++);
		ru_utime.tv_usec = std::stoul(*viter++);
		ru_stime.tv_sec = std::stoul(*viter++);
		ru_stime.tv_usec = std::stoul(*viter++);
		utime = (double) ru_utime.tv_sec + ((double) ru_utime.tv_usec) * 1e-6;
		stime = (double) ru_stime.tv_sec + ((double) ru_stime.tv_usec) * 1e-6;
		history_.pid_done(pid, utime, stime);
	    }

	    /*
	    std::cerr << "what=" << what << " pid=" << pid << " progname=" << progname << " cmd=" << cmd << " params=";
	    std::copy(params.begin(), params.end(), std::ostream_iterator<std::string>(std::cerr, " "));
	    std::cerr << " utime=" << utime << " stime=" << stime;
	    std::cerr << std::endl;
	    std::cerr << "statline: " << statline << std::endl;
	    */

	    double ut=0.0, st=0.0;
	    history_.check();
	}
	
	if (ec == boost::asio::error::eof)
	{
	    // std::cout << "EOF on fifo\n";
	    pipe.cancel();
	    pipe.close();
	    if (!exiting_)
		open_fifo();
	}
	else
	{
	    pipe.async_read_some(boost::asio::buffer(buf->data(), buf->capacity()),
				 boost::bind(&ExecutionManager::handle_fifo_data,
					     this,
					     boost::asio::placeholders::error,
					     boost::asio::placeholders::bytes_transferred,
					     boost::ref(pipe),
					     buf));
	}
    }

    void handle_fifo_open(const boost::system::error_code &ec, 
			  boost::asio::posix::stream_descriptor &pipe,
			  std::shared_ptr<OutputBuffer> buf) {
	// std::cout << "Fifo is open\n";
	
	if (ec == boost::asio::error::operation_aborted)
	{
	    std::cerr << "handle_fifo_open aborted\n";
	    return;
	}

	if (ec == boost::asio::error::eof)
	{
	    // std::cout << "EOF on fifo open\n";
	}
	else
	{
	    pipe.async_read_some(boost::asio::buffer(buf->data(), buf->capacity()),
				 boost::bind(&ExecutionManager::handle_fifo_data,
					     this,
					     boost::asio::placeholders::error,
					     boost::asio::placeholders::bytes_transferred,
					     boost::ref(pipe),
					     buf));
	}
    }

    void start_child() {

	auto stdout_buf = std::make_shared<OutputBuffer>("stdout");
	auto stderr_buf = std::make_shared<OutputBuffer>("stderr");

	child_ = bp::child(cmd_path_.string(),
			   bp::args = opt_.parameters,
			   bp::std_out > stdout_pipe_, 
			   bp::std_err > stderr_pipe_,
			   bp::env["LD_PRELOAD"] = "./p3x-preload.so",
			   bp::env["P3_SHEPHERD_FIFO"] = fifo_path_.string()
	    );
    

	history_.pid(child_.id());
	app_client_->write_block("pid", std::to_string(child_.id()) + "\n", true);
	
	stdout_pipe_.async_read_some(boost::asio::buffer(stdout_buf->data(), stdout_buf->capacity()),
				     boost::bind(&ExecutionManager::handle_data,
						 this,
						 boost::asio::placeholders::error,
						 boost::asio::placeholders::bytes_transferred,
						 boost::ref(stdout_pipe_),
						 stdout_buf));

	stderr_pipe_.async_read_some(boost::asio::buffer(stderr_buf->data(), stderr_buf->capacity()),
				boost::bind(&ExecutionManager::handle_data,
					    this,
					    boost::asio::placeholders::error,
					    boost::asio::placeholders::bytes_transferred,
					    boost::ref(stderr_pipe_), 
					    stderr_buf));
	
	/*
	 * Start measurement timer.
	 */
	
        measurement_timer_.expires_from_now(boost::posix_time::seconds(opt_.measurement_interval));
	measurement_timer_.async_wait(boost::bind(&ExecutionManager::handle_measurement,
						  this,
						  boost::asio::placeholders::error));

    }

    void open_fifo() {
	int fd = open(fifo_path_.c_str(), O_RDONLY | O_NONBLOCK);
	if (fd < 0)
	{
	    std::stringstream ss;
	    ss << "Error opening fifo at " << fifo_path_ << ": " << strerror(errno) << std::endl;
	    throw std::runtime_error(ss.str());
	}
	fifo_desc_.assign(fd);

	fifo_buf_->clear();
	fifo_desc_.async_wait(boost::asio::posix::stream_descriptor::wait_read,
			      boost::bind(&ExecutionManager::handle_fifo_open,
					 this,
					 boost::asio::placeholders::error,
					 boost::ref(fifo_desc_),
					 fifo_buf_));

	
    }

    void start_fifo_listener() {
	char fifo_path[1024];
	std::tmpnam(fifo_path);
	fifo_path_ = fifo_path;
	// std::cerr << "starting fifo on " << fifo_path_ << std::endl;

	fifo_buf_ = std::make_shared<OutputBuffer>("fifo");	

	if (mkfifo(fifo_path, 0600) < 0)
	{
	    std::stringstream ss;
	    ss << "Error creating fifo at " << fifo_path << ": " << strerror(errno) << std::endl;
	    throw std::runtime_error(ss.str());
	}

	open_fifo();
    }

    std::shared_ptr<AppClient> app_client() { return app_client_; }

private:    

    AppOptions opt_;
    fs::path cmd_path_;
    boost::asio::deadline_timer measurement_timer_;
    boost::asio::io_service &ios_;

    std::shared_ptr<AppClient> app_client_;
    
    bp::async_pipe stdout_pipe_;
    bp::async_pipe stderr_pipe_;
    int pipes_waiting_;
    bool exiting_;

    fs::path fifo_path_;
    boost::asio::posix::stream_descriptor fifo_desc_;

    bp::child child_;

    ProcessHistory history_;

    std::shared_ptr<OutputBuffer> fifo_buf_;
};

int main(int argc, char *argv[])
{
    AppOptions opt;
    opt.parse(argc, argv);

    boost::asio::io_service ios;

    ExecutionManager mgr(opt, ios);

    mgr.start_fifo_listener();

    mgr.validate_command();
    mgr.start_child();

    // We'd like to resolve our fqdn

    std::string host(boost::asio::ip::host_name());
    boost::asio::ip::tcp::resolver resolver(ios);
    resolver.async_resolve(host, "", boost::asio::ip::tcp::resolver::flags::canonical_name,
			   [&mgr, &host](const boost::system::error_code &ec,
					 boost::asio::ip::tcp::resolver::iterator iter)
			   {
			       auto ac = mgr.app_client();
			       if (ec)
			       {
				   std::cerr << "error resolving name " << ec <<std::endl;
				   ac->write_block("hostname", host + "\n", true);
			       }				   
			       else
			       {
				   ac->write_block("hostname", iter->host_name() + "\n", true);
			       }
			   });

    ios.run();
    // int res = child.exit_code();
    // std::cout << "exit code " << res << std::endl;
}
