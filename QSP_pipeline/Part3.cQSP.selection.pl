#!/usr/bin/perl
use strict;
use warnings;

# Usage
my ($info_file, $cdhit_file, $uniq_file, $QSP, $alpha_file) = @ARGV;
die "Usage: perl Part3.cQSP.selection.pl Non-Toxin.cQSP4predicton.xls QSP.clust.stat uniq.stat QSP.prediction.result.xls alphafold.seq.xls\n"
    unless @ARGV == 5;

# ======================
# Step6: QSP prediction results
# ======================
my %is_qsp;

open IN, "<$QSP" or die $!;
<IN>;
while (<IN>) {
    chomp;
    next if /non-QSP/;
    my ($id, $m) = (split /\t/)[0,-1];
    $is_qsp{$id} = $m;
}
close IN;

# =========================
# Step1: CD-HIT cluster results
# =========================
my (%cluster_count, %uniq_stat);

open my $cd, "<", $cdhit_file or die $!;
while (<$cd>) {
    chomp;
    my @a = split /\t/;
    my $seq = $a[0];
    my $count = $a[-2];

    # all 5-17aa sequences
    for (my $len = 17; $len >= 5; $len--) {
        my $offset = 17 - $len;
        my $sub = substr($seq, $offset);
        $cluster_count{$sub} += $count;
    }
}
close $cd;

open IN, "<$uniq_file" or die $!;
while (<IN>) {
	chomp;
	my @a = split /\t/;
	$uniq_stat{$a[0]}=$a[1];
}
close IN;

# =========================
# Step2: alphafold2 prediction results
# =========================
my %alpha;
open my $af, "<", $alpha_file or die $!;
<$af>;
while (<$af>) {
	chomp;
	my @a = split /\t/;
	$alpha{$a[1]} = $a[2];
}
close $af;


# =========================
# Step4: final filter & selection
# =========================
open IN, "-|", "tail -n +2 $info_file | sort -k1 -r " or die $!;
open OUT, ">", "all.cQSP.filter.xls";
open OUF, ">", "Final.cQSP.filter.xls";

my $header = "ID\tName\tSequence\tToxin3 ML Score\tToxin3 Prediction\tToxin3 PPV\tQSP Prediction\tCount\tCluster_num\tAlphafold2_helix\n";
print OUT "$header";
print OUF "$header";
my $id=0;

while (<IN>) {
    chomp;
    my @a = split /\t/;
	my $seq_id = $a[0];
    my $seq = $a[1];
    my $score = $a[2];

	next unless exists $is_qsp{$seq_id};
	if (not exists $alpha{$seq}) {$alpha{$seq}=0;}
	$id++;

	my $out="cQSP_$id\t$_\t$is_qsp{$seq_id}\t$uniq_stat{$seq}\t$cluster_count{$seq}\t$alpha{$seq}\n";
	print OUT $out;
	if ($score <= 0.32 && $cluster_count{$seq} >=3 && $alpha{$seq}>0) {
		print OUF $out;
	}

}
close IN;
close OUT;

print "Done!\nOutput: all.cQSP.filter.xls, Final.cQSP.filter.xls\n";
