#ifndef _pidinfo_h
#define _pidinfo_h

#include <iostream>
#include <vector>
#include <map>
#include <sys/types.h>

class PidInfo
{
public:
    PidInfo();
    PidInfo(pid_t pid);

    pid_t pid() { return pid_; }
    pid_t ppid() { return ppid_; }

    size_t vm_pss();
    size_t vm_size() { return vm_size_; }
    size_t vm_rss() { return vm_rss_; }
    const std::string &name() { return name_; }

private:
    pid_t pid_;
    pid_t ppid_;
    size_t vm_size_;
    size_t vm_rss_;
    std::string name_;

    friend std::ostream &operator<<(std::ostream &os, const PidInfo &pi);
};

inline std::ostream &operator<<(std::ostream &os, const PidInfo &pi)
{
    os << "pid=" << pi.pid_ << " name=" << pi.name_ << " ppid=" << pi.ppid_ << " vm_size=" << pi.vm_size_ << " vm_rss=" << pi.vm_rss_;
}

struct ProcessStats
{
    ProcessStats() :  count(0), vm_size(0), vm_rss(0), vm_pss(0) {}
    int count;
    size_t vm_size;
    size_t vm_rss;
    size_t vm_pss;
};

class PidMap
{
public:
    PidMap();
    std::vector<pid_t> children_of(pid_t p);
    ProcessStats compute_stats(pid_t p);

private:
    std::map<pid_t, PidInfo> pid_map_;
    std::map<pid_t, std::vector<pid_t> > children_of_;
};

#endif
