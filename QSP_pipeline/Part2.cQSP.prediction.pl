#!/usr/bin/perl
use strict;
use warnings;
use Cwd 'abs_path';

my ($config, $input, $outdir) = @ARGV;
die "Usage: perl cQSP_pipeline.pl config.txt all_cQSP.pro-peptide.fa output_dir\n" unless $input;
$outdir=abs_path($outdir);

# ======================
# Read config
# ======================
my %cfg;
open my $cf, '<', $config or die $!;
while (<$cf>) {
    chomp;
    next if /^#/ || /^\s*$/;
    my ($k, $v) = split /=/;
    $cfg{$k} = $v;
}
close $cf;

# ======================
# Step1: CD-HIT
# ======================
open IN, "<", $input;
open OUT, ">$outdir/all_cQSP.8letters.fa";
open OUL, ">$outdir/all_cQSP.8letters.list";

local $/ = ">";
<IN>;
my %list;
while (<IN>) {
    chomp;
	my ($seq_id, $seq_raw)=split/\n/;
	my $seq = $seq_raw;
	$seq_id=(split/\s+/,$seq_id)[0];
	$list{$seq_id}=$seq_raw;

    $seq =~ s/[LVIMC]/L/g;
    $seq =~ s/[AG]/A/g;
    $seq =~ s/[ST]/S/g;
    $seq =~ s/[FYW]/F/g;
    $seq =~ s/[EDNQ]/E/g;
    $seq =~ s/[KR]/K/g;

    print OUT ">$seq_id\n$seq\n";
	print OUL "$seq_id\t$seq_raw\t$seq\n";
}
close IN;
close OUT;
close OUL;

system("$cfg{CDHIT} -i $outdir/all_cQSP.8letters.fa -o $outdir/QSP.clust.fa -c $cfg{CDHIT_C} -n $cfg{CDHIT_N} -T $cfg{CPU} -p 1 -g 1 -d 0 -s 0.85 -aL 0.85 -aS 0.85  -M 10000");

open IN, "<$outdir/QSP.clust.fa.clstr";
open OUT, ">$outdir/QSP.clust.stat";

local $/ = ">Cluster ";
<IN>;
while (<IN>) {
	chomp;
	my @id=split/\n/;
	for (my $i=1; $i<@id; $i++) {
		#if ($id[$i] =~ /\*$/) {
			my $g=(split/\>|\.\.\.\s/,$id[$i])[1];
			print OUT "$list{$g}\t$g\t$#id\tCluster$id[0]\n";
			#	last;
			#}
	}
}

close IN;
close OUT;

# ======================
# Step2: sliding-window extract 5-17aa sequences
# ======================
open IN, "<", $input;
open OUT, ">$outdir/split.fa";

local $/ = ">";
<IN>;
while (<IN>) {
    chomp;
    my ($h, $seq) = split /\n/;
    $h = (split /\s+/, $h)[0];

	for (my $i=17;$i>=5;$i--) {
		my $j=17-$i;
        my $sub = substr($seq, $j);
        print OUT ">$h\_seq$i\n$sub\n";
    }
}
close IN;
close OUT;

# ======================
# Step3: generate unique peptide sequences for QSP prediction and toxin prediction
# ======================
my (%uniq, %freq);
open IN, "<", "$outdir/split.fa";
local $/ = ">";
<IN>;

while (<IN>) {
    chomp;
    my ($h, $seq) = split /\n/;
    $uniq{$seq}.="$h,";
    $freq{$seq}++;
}
close IN;

open OUT, ">$outdir/uniq.fa";
open STAT, ">$outdir/uniq.stat";

for my $seq (sort {$freq{$b}<=>$freq{$a}} keys %freq) {
    my $id = (split/\,/,$uniq{$seq})[0];
    print OUT ">$id\n$seq\n";
    print STAT "$seq\t$freq{$seq}\t$uniq{$seq}\n";
}
close OUT;
close STAT;

## PSRQSP prediction for peptides with length > 7aa was performed online at https://pmlabstack.pythonanywhere.com/PSRQSP
## PreTP-2L prediction for peptides with length ≤ 7aa was performed online at http://bliulab.net/PreTP-2L/
## TPpred-PepPA http://bliulab.net/TPpred-PepPA/
## QSPepPred http://crdd.osdd.net/servers/qsppred/predictor.html

# ======================
# Step4: toxin prediction and filter
# ======================
system("$cfg{TOXINPRED} -i $outdir/uniq.fa -o $outdir/toxin.csv -t $cfg{TOXIN_THRESHOLD} -m1");

open IN, "<", "$outdir/toxin.csv";
open OUT, ">$outdir/Non-Toxin.cQSP4predicton.xls";
open FA, ">$outdir/Non-Toxin.cQSP4predicton.fa";

local $/ = "\n";
chomp(my $t=<IN>);
$t=~s/\,/\t/g;
print OUT "$t\n";

while (<IN>) {
    chomp;
	next if ($_ !~ /Non-Toxin/);
    s/\,/\t/g;
    my @a = split /\t/;
    my ($seq_id, $seq) = ($a[0],$a[1]);

    print OUT "$_\n";
    print FA ">$seq_id\n$seq\n";
}
close IN;
close OUT;
close FA;

## peptide structure preditcion for "Non-Toxin.cQSP4predicton.fa" was performed by Alphafold2.

print "Finished! Output:\nNon-Toxin.cQSP.fa\nNon-Toxin.cQSP.xls\n";
