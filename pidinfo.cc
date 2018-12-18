#include "pidinfo.h"

#include <boost/filesystem.hpp>
#include <boost/algorithm/string/predicate.hpp>
#include <boost/regex.hpp>

#include <string>
#include <deque>
#include <iostream>
#include <unistd.h>

namespace fs = boost::filesystem;

PidInfo::PidInfo() : pid_(0)
{
}

PidInfo::PidInfo(pid_t pid) : pid_(pid)
{
    fs::path path("/proc");
    path /= std::to_string(pid);

    fs::path status_path = path / "status";
    fs::ifstream ifstr(status_path);

    std::string line;

    const boost::regex re("^(PPid|VmSize|VmRSS):\\s+(\\d+)(\\s+kB)?");
    const boost::regex nre("^Name:\\s+(.*)$");

    while (std::getline(ifstr, line))
    {
	boost::smatch match;
	if (boost::regex_match(line, match, re))
	{
	    std::string tag(match[1]);
	    std::string val(match[2]);
	    std::string kb(match[3]);
	    size_t ival = std::stoul(val);
	    if (tag == "PPid")
		ppid_ = ival;
	    else if (tag == "VmSize")
		vm_size_ = ival * 1024;
	    else if (tag == "VmRSS")
		vm_rss_ = ival * 1024;
	}
	else if (name_.empty() && boost::regex_match(line, match, nre))
	{
	    name_ = match[1];
	}
    }
}

size_t PidInfo::vm_pss()
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

PidMap::PidMap()
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

std::vector<pid_t> PidMap::children_of(pid_t p)
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

ProcessStats PidMap::compute_stats(pid_t p)
{
    ProcessStats stats;
    std::cerr << "measuring\n";
    for (pid_t proc: children_of(p))
    {
	auto &pi = pid_map_[proc];

	std::cerr << pi << "\n";
	stats.count++;
	stats.vm_size += pi.vm_size();
	stats.vm_rss += pi.vm_rss();
	stats.vm_pss += pi.vm_pss();
    }
    return stats;
}

#ifdef PIDINFO_TEST_MAIN
int main(int argc, char *argv[])
{
    pid_t pid = getpid();

    if (argc > 1)
	pid = std::stoi(argv[1]);
    
    PidMap pm;

    auto x = pm.compute_stats(pid);
    std::cout << x.count << " " << x.vm_size / 1024 << " " << x.vm_rss / 1024 << " " << x.vm_pss / 1024 << "\n";
}
#endif
