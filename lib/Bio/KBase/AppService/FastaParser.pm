package Bio::KBase::AppService::FastaParser;

use strict;
use base 'Exporter';
our @EXPORT_OK = qw(parse_fasta);

our $max_id_len = 70;

sub parse_fasta
{
    my($fh, $clean_fh, $on_seq) = @_;

    my $state = 'expect_header';
    my $cur_id;

    my %ids_seen;
    my $cur_seq_len;
    my @empty_sequences;
    my @bad_ids;
    my @long_ids;
    my $cur_seq;
    eval {
	while (<$fh>)
	{
	    chomp;
	    
	    if ($state eq 'expect_header')
	    {
		if (/^>(\S+)/)
		{
		    $cur_id = $1;
		    push(@bad_ids, $cur_id) if ($cur_id =~ /,/);
		    push(@long_ids, $cur_id) if length($cur_id) > $max_id_len;
			
		    $ids_seen{$cur_id}++;
		    $state = 'expect_data';
		    print $clean_fh ">$cur_id\n" if $clean_fh;
		    $cur_seq_len = 0;
		    next;
		}
		else
		{
		    die "Invalid fasta: Expected header at line $.\n";
		}
	    }
	    elsif ($state eq 'expect_data')
	    {
		if (/^>(\S+)/)
		{
		    if (defined($cur_seq_len) && $cur_seq_len == 0)
		    {
			push(@empty_sequences, $cur_id);
		    }
		    my $continue = $on_seq->($cur_id, $cur_seq);
		    return unless $continue;
		    $cur_seq = '';
		    $cur_seq_len = 0;
		    $cur_id = $1;
		    push(@bad_ids, $cur_id) if ($cur_id =~ /,/);
		    push(@long_ids, $cur_id) if length($cur_id) > $max_id_len;
		    $ids_seen{$cur_id}++;
		    $state = 'expect_data';
		    print $clean_fh ">$cur_id\n" if $clean_fh;
		    next;
		}
		#
		# Strip any whitespace - we will allow it.
		#
		s/\s*//g;
		if (/^([acgtumrwsykbdhvn]*)\s*$/i)
		{
		    print $clean_fh lc($1) . "\n" if $clean_fh;
		    $cur_seq_len += length($1);
		    $cur_seq .= lc($1);
		    next;
		}
		elsif (/^[*abcdefghijklmnopqrstuvwxyz]*\s*$/i)
		{
		    die "Invalid fasta: Bad data (appears to be protein translation data) at line $.\n";
		}
		else
		{
		    my $str = $_;
		    if (length($_) > 100)
		    {
			$str = substr($_, 0, 50) . " [...] " . substr($_, -50);
		    }
		    die "Invalid fasta: Bad data at line $.:\n$str\n";
		}
	    }
	    else
	    {
		die "Internal error: invalid state $state\n";
	    }
	}
	if (defined($cur_id))
	{
	    my $continue = $on_seq->($cur_id, $cur_seq);
	    return unless $continue;
	    
	}
	    
    };
    if ($@)
    {
	#
	# error during parse, clean up & rethrow.
	#
	die $@;
    }

    #
    # Check for ID uniqueness.
    #
    my @duplicate_ids = grep { $ids_seen{$_} > 1 } keys %ids_seen;
    my $errs;
    if (@duplicate_ids)
    {
	my $n = @duplicate_ids;
	if ($n > 10)
	{
	    $#duplicate_ids = 10;
	    push(@duplicate_ids, "...");
	}
	$errs .= "$n duplicate sequence identifiers were found:\n" . join("", map { "\t$_\n" } @duplicate_ids);
    }
    if (@empty_sequences)
    {
	my $n = @empty_sequences;
	if ($n > 10)
	{
	    $#empty_sequences = 10;
	    push(@empty_sequences, "...");
	}
	$errs .= "$n empty sequences were found:\n" . join("", map { "\t$_\n" } @empty_sequences);
    }
    if (@bad_ids)
    {
	my $n = @bad_ids;
	if ($n > 10)
	{
	    $#bad_ids = 10;
	    push(@bad_ids, "...");
	}
	my $t = $n == 1 ? "id was" : "ids were";
	$errs .= "$n bad $t found:\n" . join("", map { "\t$_\n" } @bad_ids) .
	    "Commas are not allowed in sequence IDs in RAST\n";
    }
    if (@long_ids)
    {
	my $n = @long_ids;
	if ($n > 10)
	{
	    $#long_ids = 10;
	    push(@long_ids, "...");
	}
	my $t = $n == 1 ? "id was" : "ids were";
	#$errs .= "$n long $t found:\n" . join("", map { "\t$_\n" } @long_ids) .
	#    "Sequence IDs are limited to $max_id_len characters or fewer in RAST.\n";
    }
    die "\n$errs" if $errs;
}

1;
