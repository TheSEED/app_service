#include "pidinfo.h"

#include <boost/filesystem.hpp>
#include <boost/algorithm/string/predicate.hpp>
#include <boost/algorithm/string.hpp>
#include <boost/regex.hpp>

#include <string>
#include <deque>
#include <iostream>
#include <algorithm>
#include <unistd.h>

#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <sys/time.h>

static unsigned long p3x_calc_start_time_offset();

namespace fs = boost::filesystem;

size_t PidInfo::page_size_ = sysconf(_SC_PAGE_SIZE);
unsigned long PidInfo::clock_tick_ = (unsigned long) sysconf(_SC_CLK_TCK);
unsigned long PidInfo::boot_time_ = ([]() {
	unsigned long val = p3x_calc_start_time_offset();
	if (val)
	    return val;
	std::ifstream ifstr("/proc/stat");
	std::string line;
	unsigned long btime = 0;
	while (std::getline(ifstr, line))
	{
	    if (line.compare(0, 6, "btime ") == 0)
	    {
		try {
		    btime = std::stoul(line.substr(6));
		} catch (std::exception &e)
		{
		    std::cerr << "Bad parse of " << line.substr(6) << ": " << e.what() << std::endl;
		}
		std::cout << "ok " << line << " btime= " << btime <<  std::endl;
	    }
	}
	return btime * 100;
	
    })();
	
PidInfo::PidInfo()
  : pid_(0)
  , ppid_(0)
  , vm_size_(0)
  , vm_rss_(0)
  , utime_(0.0)
  , stime_(0.0)
  , active_(false)
  , have_precise_finish_data_(false)
  , valid_(false)
{
}

PidInfo::PidInfo(pid_t pid)
  : pid_(pid)
  , ppid_(0)
  , vm_size_(0)
  , vm_rss_(0)
  , utime_(0.0)
  , stime_(0.0)
  , active_(true)
  , have_precise_finish_data_(false)
  , valid_(false)
{
    fs::path path("/proc");
    path /= std::to_string(pid);

    try {
	fs::path exe = fs::read_symlink(path / "exe");
	if (!exe.empty())
	    exe_ = exe.string();
    } catch (boost::filesystem::filesystem_error &e)
    {
    }

    std::string line;

    fs::path status_path = path / "stat";
    fs::ifstream ifstr(status_path);

    if (std::getline(ifstr, line))
    {
	// Parse out program name using parens
	valid_ = true;

	size_t s = line.find("(");
	if (s == std::string::npos)
	    goto bad;
	size_t s2 = line.find(")", s + 1);
	if (s2 == std::string::npos)
	    goto bad;
	name_ = line.substr(s+1, s2 - s - 1);

	std::vector<std::string> cols;
	std::string rest = line.substr(s2 + 2);
	boost::split(cols, rest, boost::is_any_of(" "));

	//
	// index to cols[] below is the index in the proc.5 manpage
	// minus 3
	//

	try {
	    ppid_ = std::stoul(cols[1]);
	    start_time_ = p3_clock::time_point{std::chrono::microseconds{boot_time_ * 10000 + stoul(cols[19]) * 1000000 / clock_tick_}};
	    vm_size_ = std::stoul(cols[20]);
	    vm_rss_ = std::stoul(cols[21]) * page_size_;
	    utime_ = (double) std::stoul(cols[11]) / clock_tick_;
	    stime_ = (double) std::stoul(cols[12]) / clock_tick_;
	} catch (std::exception &e)
	{
	    std::cerr << "Bad parse of " << status_path << ": " << e.what() << std::endl;
	}
    }
    return;
bad:
    std::cout << "badness\n";
}

/*
 * At each measurement tick, update the pidinfo with the dyanmic info from other.
 *
 * We update the latest utime/stime, and accumulate the maximum memory use seen.
 */
void PidInfo::update_stats(PidInfo &other)
{
    vm_size_ = std::max(vm_size_, other.vm_size());
    vm_rss_ = std::max(vm_rss_, other.vm_rss());
    if (!have_precise_finish_data_)
    {
	utime_ = other.utime();
	stime_ = other.stime();
    }
}

size_t PidInfo::vm_pss() const
{
    fs::path proc{"/proc"};
    proc /= std::to_string(pid_);
    proc /= "smaps";

    fs::ifstream ifstr{proc};

    std::string line;

    const boost::regex re("^Pss:\\s+(\\d+)(\\s+kB)?");

    size_t total = 0;
    while (std::getline(ifstr, line))
    {
	boost::smatch match;
	if (boost::regex_match(line, match, re))
	{
	    size_t ival = std::stoul(match[1]) * 1024;
	    total += ival;
	}
    }
    return total;
}

double PidInfo::user_utilization(const p3_time_point &now) const
{
    return utime_ / elapsed(now);
}

double PidInfo::sys_utilization(const p3_time_point &now) const
{
    return stime_ / elapsed(now);
}

double PidInfo::elapsed(const p3_time_point &now) const
{
    auto elap = now - start_time_;
    return std::chrono::duration<double>(elap).count();
}

SystemProcessState::SystemProcessState()
{
    fs::path proc{"/proc"};

    fs::directory_iterator piter{proc};
    for (auto p: piter)
    {
	std::string b{p.path().filename().string()};
	if (b.find_first_not_of("0123456789") != std::string::npos)
	    continue;
	PidInfo pi(std::stoi(b));
	pid_map_.insert(std::pair<pid_t, PidInfo>(pi.pid(), pi));
	children_of_[pi.ppid()].push_back(pi.pid());
    }
}

std::vector<pid_t> SystemProcessState::children_of(pid_t p)
{
    std::vector<pid_t> ret;
    std::deque<pid_t> q;
    q.push_back(p);

    while (!q.empty())
    {
	pid_t p = q.front();
	q.pop_front();
	ret.push_back(p);
	auto x = children_of_.find(p);
	if (x != children_of_.end())
	{
	    std::copy(x->second.begin(), x->second.end(), std::back_inserter(q));
	}
    }

    return ret;
}

void ProcessHistory::check()
{
    SystemProcessState sys_state;

    std::set<pid_t> active_pids;
    for (auto &x: status_)
    {
	if (x.second.active())
	    active_pids.emplace(x.first);
    }

    for (pid_t proc: sys_state.children_of(pid_))
    {
	auto pstate = sys_state.info_for(proc);
	if (!pstate)
	{
	    std::cerr << "No state for " << proc << std::endl;
	    continue;
	}

	// std::cerr << *pstate << std::endl;

	// determine if we had state before.

	auto active_iter = active_pids.find(proc);
	if (active_iter == active_pids.end())
	{
	    status_.emplace(std::make_pair(proc, *pstate));
	    std::cerr << "new proc: " << *pstate << std::endl;
	}
	else
	{
	    // It's still active so erase
	    active_pids.erase(active_iter);

	    // Update record with new status
	    status_[proc].update_stats(*pstate);
	}
    }

    // Items in the active set that are no longer active need to be updated
    // Mark as inactive, and update status
    for (auto inactive_pid: active_pids)
    {
	auto &s = status_[inactive_pid];
	s.set_finish_time(p3_clock::now());
	std::cerr << " proc " << inactive_pid << " finished\n";
	std::cerr << s << std::endl;
    }
}

void ProcessHistory::get_cumulative_times(double &utime, double &stime)
{
    utime = stime = 0.0;
    for (auto ent: status_)
    {
	auto &pstate = ent.second;

	utime += pstate.utime();
	stime += pstate.stime();
    }
}

void ProcessHistory::pid_new(pid_t pid, const std::string &exe, const std::vector<std::string> &params)
{
    auto cur = status_.find(pid);
    if (cur == status_.end())
    {
	/* First time seen.
	 * Create a new PidInfo record to pull all the initial data, and 
	 */
	std::cerr << "creating new pid record for " << pid << " " << exe << std::endl;
	auto ret = status_.emplace(std::make_pair(pid, PidInfo{pid}));
	// std::cerr << ret.first->second;
    }
    else
    {
	// std::cerr << "already have new pid\n";
    }
}

void ProcessHistory::pid_done(pid_t pid, double utime, double stime)
{
    auto cur = status_.find(pid);
    if (cur == status_.end())
    {
	std::cerr << "missed the creation of " << pid << std::endl;
    }
    else
    {
	cur->second.set_precise_finish(utime, stime);
    }
}


#ifdef PIDINFO_TEST_MAIN
int main(int argc, char *argv[])
{
    pid_t pid = getpid();

    if (argc > 1)
	pid = std::stoi(argv[1]);
    
    ProcessHistory phistory(pid);
    phistory.check();

//    auto x = pm.compute_stats(pid);
//    std::cout << x.count << " " << x.vm_size / 1024 << " " << x.vm_rss / 1024 << " " << x.vm_pss / 1024 << "\n";
}
#endif

//
// Use high resolution clock and starting time of this process to get a
// better estimate of boot time offset used in calculating process start time.
//
static unsigned long p3x_calc_start_time_offset()
{
    struct timeval tv;

    gettimeofday(&tv, 0);

    char path[1024];
    sprintf(path, "/proc/%d/stat", getpid());
    
    FILE *fp = fopen(path, "r");
    if (fp)
    {
	char line[1024];
	if (fgets(line, sizeof(line), fp))
	{
	    char *s = line;
	    int i;
	    for (i = 0; s && i < 21; i++)
	    {
		char *e = index(s, ' ');
		if (e)
		    s = e + 1;
		else
		    s = 0;
	    }
	    if (s)
	    {
		char *e = index(s, ' ');
		if (e)
		{
		    *e = 0;

		    unsigned long l = atol(s);
		    unsigned long t = tv.tv_sec * 100 + tv.tv_usec / 10000;
		    return t - l;
		}
	    }
	}
	fclose(fp);
    }
    return 0;
}
