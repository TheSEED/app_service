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

#include <iostream>
#include <fstream>
#include <istream>
#include <ostream>
#include <string>
#include <vector>
#include <memory>

#include <unistd.h>

#include "pidinfo.h"

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

template <int N>
class OutputBufferT
{
public:
    OutputBufferT(const std::string &key) : key_(key) {
	memset(buffer_, 0, N+1);
    }

    size_t size() { return N; }
    char *data() { return buffer_; }
    const std::string &key() { return key_; }
    std::string as_string() { return std::string(buffer_, N); }

private:
    std::string key_;
    char buffer_[N+1];
    
};

const int OutputBufferSize = 4096;
typedef OutputBufferT<OutputBufferSize> OutputBuffer;

class ExecutionManager
{
public:
    ExecutionManager(const AppOptions &opt, boost::asio::io_service &ios) :
	opt_(opt),
	measurement_timer_(ios),
	ios_(ios),
	stdout_pipe_(ios),
	stderr_pipe_(ios),
	pipes_waiting_(2) {
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
	std::cerr << "found command: " << cmd_path_ << std::endl;
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

    void measure_child() {
	PidMap pm;
	auto stats = pm.compute_stats(child_.id());
	std::cout << stats.count << " " << stats.vm_size / 1024 << " " << stats.vm_rss / 1024 << " " << stats.vm_pss / 1024 << "\n";	
    }

    void handle_data(const boost::system::error_code &ec, std::size_t size,
		     bp::async_pipe &pipe,
		     std::shared_ptr<OutputBuffer> buf) {
	std::cout << buf->key() << " read of size " << size << " ec=" << ec << std::endl;
	
	if (size > 0)
	    std::cout << buf->as_string() << std::endl;
	
	if (ec == boost::asio::error::eof)
	{
	    std::cout << "done reading " << buf->key() << std::endl;
	    pipes_waiting_--;

	    // Check for child having finished.
	    if (pipes_waiting_ == 0)
	    {
		std::cerr << "Child is finished\n";
		measurement_timer_.cancel();
		measure_child();
	    }
	}
	else
	{
	    pipe.async_read_some(boost::asio::buffer(buf->data(), buf->size()),
				 boost::bind(&ExecutionManager::handle_data,
					     this,
					     boost::asio::placeholders::error,
					     boost::asio::placeholders::bytes_transferred,
					     boost::ref(pipe),
					     buf));
	}
    }

    void start_child() {

	stdout_buf_ = std::make_shared<OutputBuffer>("stdout");
	stderr_buf_ = std::make_shared<OutputBuffer>("stderr");

	child_ = bp::child(cmd_path_.string(),
			bp::args = opt_.parameters,
			bp::std_out > stdout_pipe_, 
			bp::std_err > stderr_pipe_);
    
	stdout_pipe_.async_read_some(boost::asio::buffer(stdout_buf_->data(), stdout_buf_->size()),
				     boost::bind(&ExecutionManager::handle_data,
						 this,
						 boost::asio::placeholders::error,
						 boost::asio::placeholders::bytes_transferred,
						 boost::ref(stdout_pipe_),
						 stdout_buf_));

	stderr_pipe_.async_read_some(boost::asio::buffer(stderr_buf_->data(), stderr_buf_->size()),
				boost::bind(&ExecutionManager::handle_data,
					    this,
					    boost::asio::placeholders::error,
					    boost::asio::placeholders::bytes_transferred,
					    boost::ref(stderr_pipe_), 
					    stderr_buf_));
	
	/*
	 * Start measurement timer.
	 */
	
        measurement_timer_.expires_from_now(boost::posix_time::seconds(opt_.measurement_interval));
	measurement_timer_.async_wait(boost::bind(&ExecutionManager::handle_measurement,
						  this,
						  boost::asio::placeholders::error));

    }
private:    

    AppOptions opt_;
    fs::path cmd_path_;
    boost::asio::deadline_timer measurement_timer_;
    boost::asio::io_service &ios_;
    bp::async_pipe stdout_pipe_;
    bp::async_pipe stderr_pipe_;
    int pipes_waiting_;

    bp::child child_;

    std::shared_ptr<OutputBuffer> stdout_buf_;
    std::shared_ptr<OutputBuffer> stderr_buf_;
};

int main(int argc, char *argv[])
{
    AppOptions opt;
    opt.parse(argc, argv);

    boost::asio::io_service ios;

    ExecutionManager mgr(opt, ios);

    mgr.validate_command();
    mgr.start_child();

    ios.run();
    // int res = child.exit_code();
    // std::cout << "exit code " << res << std::endl;
}
