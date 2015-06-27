#!/usr/bin/env perl
use strict;
use warnings;
use feature 'say';
use autodie;
use File::Path qw(make_path);
use Getopt::Long;

my $usage = "

Synopsis:

    UGP_Result_Cleanup.pl -dir <path> --run

Description:

    Will take UGPp output directory and organize files into proper collections.


 Required options:

    --input_directory, -dir Directory to clean up.

Additional options:

    --run, -r   Run the clean up steps.  [DEFAULT: view data movement].
    
\n";

my ( $dir, $run );
GetOptions(
    "input_directory|dir=s" => \$dir,
    "run|r"                 => \$run,
);
die $usage unless $dir;
my $review = '1' unless $run;
$dir =~ s/\/$//;

say "Moving to $dir to create directory structure...";
chdir $dir;
make_path(
    'Intermediate_Files', 'Reports',    'VCF', 'VCF_QC',
    'Data/BAM',           'Data/Fastq', 'Data/Trimming',
) if $run;

##----------------------------------------##

say "Collecting BAM files...";
my @bams = `find $dir -name \"*_recal.ba*\"`;
chomp(@bams);

map { `mv $_ $dir/Data/BAM` } @bams     if $run;
map { say "mv $_ $dir/Data/BAM" } @bams if $review;

##----------------------------------------##

say "Collecting UGPp files...";
my @UGPp = `find $dir -name \"UGPp*\"`;
chomp(@UGPp);

map { `mv $_ $dir/VCF` } @UGPp     if $run;
map { say "mv $_ $dir/VCF" } @UGPp if $review;

##----------------------------------------##

say "Collecting gCat files...";
my @gcat = `find $dir -name \"*gCat*\"`;
chomp(@gcat);

map { `mv $_ $dir/VCF` } @gcat     if $run;
map { say "mv $_ $dir/VCF" } @gcat if $review;

##----------------------------------------##

say "Collecting Report files...";
my @pdf      = `find $dir -name \"*.pdf\"`;
my @metrics  = `find $dir -name \"*metrics\"`;
my @flagstat = `find $dir -name \"*.flagstat\"`;
my @r        = `find $dir -name \"*.R\"`;
my @fastqc   = `find $dir -name \"*fastqc*\"`;
my @stats    = `find $dir -name \"*.stats\"`;
chomp( @pdf, @metrics, @flagstat, @r, @fastqc, @stats );

my @reports = ( @pdf, @metrics, @flagstat, @r, @fastqc, @stats );
map { `mv $_ $dir/Reports` } @reports     if $run;
map { say "mv $_ $dir/Reports" } @reports if $review;

##----------------------------------------##

say "Collecting Fastq files(*gz)...";
my @fq = `find $dir -name "*.gz"`;
chomp(@fq);

map { say "mv $_ $dir/Data/Fastq" } @fq if $review;
map { `mv $_ $dir/Data/Fastq` } @fq if $run;

##----------------------------------------##

say "Collecting intermediate files...";
my @inters = `find $dir -maxdepth 1 -type f -name \"*\"`;
chomp(@inters);

map { `mv $_ $dir/Intermediate_Files` } @inters     if $run;
map { say "mv $_ $dir/Intermediate_Files" } @inters if $review;

##----------------------------------------##

say "Cleaning up...";
my @clean = `find $dir -type l`;
my @list  = `find $dir -name \"*list\"`;
my @interval  = `find $dir -name \"*intervals\"`;
chomp (@clean, @list, @interval);

my @tidy = (@clean, @list, @interval);

map { `rm $_` } @tidy if $run;
map { say "rm $_" } @tidy if $review;

##----------------------------------------##

say "Done!!";
say "Please review Intermediate_Files directory, then remove to save space";
