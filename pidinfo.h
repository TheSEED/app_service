#ifndef _pidinfo_h
#define _pidinfo_h

#include <experimental/optional>
#include <iostream>
#include <vector>
#include <map>
#include <sys/types.h>
#include <string.h>

#include "clock.h"

class PidInfo
{
public:
    PidInfo();
    PidInfo(pid_t pid);

    void update_stats(PidInfo &other);

    pid_t pid() const { return pid_; }
    pid_t ppid() const { return ppid_; }

    size_t vm_pss() const;
    size_t vm_size() const { return vm_size_; }
    size_t vm_rss() const { return vm_rss_; }
    double utime() const { return utime_; }
    double stime() const { return stime_; }
    bool active() const { return active_; }

    p3_time_point start_time() const { return start_time_; }
    void set_finish_time(p3_time_point f) {
	finish_time_ = f;
	active_ = false;
    }
    p3_time_point finish_time() const { return finish_time_; }

    void set_precise_finish(double utime, double stime) {
	if (!have_precise_finish_data_)
	{
	    utime_ = utime;
	    stime_ = stime;
	    have_precise_finish_data_ = true;
	}
    }
    const std::string &name() const { return name_; }
    const std::string &exe() const { return exe_; }

    double user_utilization(const p3_time_point &now) const;
    double sys_utilization(const p3_time_point &now) const;
    double elapsed(const p3_time_point &now) const;

private:
    pid_t pid_;
    pid_t ppid_;
    std::string exe_;
    size_t vm_size_;
    size_t vm_rss_;
    double utime_;
    double stime_;
    p3_time_point start_time_;
    p3_time_point finish_time_;
    bool active_;
    // true if we logged the finish data via one of the LD_PRELOAD hooks
    bool have_precise_finish_data_;
    // true if the process was around long enough to log data
    bool valid_;
    std::string name_;

    friend std::ostream &operator<<(std::ostream &os, const PidInfo &pi);

    static size_t page_size_;
    static unsigned long clock_tick_;
    static unsigned long boot_time_;
};

inline std::ostream &operator<<(std::ostream &os, const PidInfo &pi)
{
    struct tm tm;

    p3_clock::time_point now = pi.active() ? p3_clock::now() : pi.finish_time();

    time_t t = p3_clock::to_time_t(pi.start_time_);
    localtime_r(&t, &tm);
    char tbuf[1024];
    asctime_r(&tm, tbuf);
    if (char *s = index(tbuf, '\n'))
	*s = 0;

    time_t e = p3_clock::to_time_t(now);
    localtime_r(&e, &tm);
    char ebuf[1024];
    asctime_r(&tm, ebuf);
    if (char *s = index(ebuf, '\n'))
	*s = 0;
    
    os << "pid=" << pi.pid_ << " name=" << pi.name_ << " exe=" << pi.exe_ << " ppid=" << pi.ppid_
       << " vm_size=" << pi.vm_size_ << " vm_rss=" << pi.vm_rss_
       << " utime=" << pi.utime_ << " stime=" << pi.stime_
       << " start_time=" << tbuf
       << " end_time=" << ebuf
       << " elapsed=" << pi.elapsed(now) 
       << " user_util=" << pi.user_utilization(now) << " sys_util=" << pi.sys_utilization(now)
       << " precise_finish=" << pi.have_precise_finish_data_
       << " valid=" << pi.valid_;
    return os;
}

class SystemProcessState
{
public:
    SystemProcessState();
    std::vector<pid_t> children_of(pid_t p);
    std::experimental:: optional<PidInfo> info_for(pid_t p) {
	auto iter = pid_map_.find(p);
	if (iter == pid_map_.end())
	    return {};
	else
	    return iter->second;
    };

private:
    std::map<pid_t, PidInfo> pid_map_;
    std::map<pid_t, std::vector<pid_t> > children_of_;
};

/*
 * Process history keeps track of all child processes created,
 * their start and completion times (to within the time-check granularity),
 * and their resource utilization.
 */
class ProcessHistory
{
public:
    ProcessHistory(pid_t pid = 0) : pid_(pid) {}
    void get_cumulative_times(double &utime, double &stime);
    void check();
    void pid_new(pid_t pid, const std::string &exe, const std::vector<std::string> &params);
    void pid_done(pid_t pid, double utime, double stime);

    void pid(pid_t pid) { pid_ = pid; }

    const std::map<pid_t, PidInfo> &status() const { return status_; }
    
private:
    pid_t pid_;

    std::map<pid_t, PidInfo> status_;
    
};

#endif
