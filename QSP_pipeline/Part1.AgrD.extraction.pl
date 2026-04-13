#!/usr/bin/perl
use strict;
use warnings;
use Cwd 'abs_path';

# Usage
my ($config, $genome_list, $outdir) = @ARGV;
die "Usage: perl Part1.AgrD.extraction.pl config.txt genome.list output_dir\n" unless $genome_list;
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
# Step1: Prokka
# ======================
open my $gl, '<', $genome_list or die $!;
while (<$gl>) {
    chomp;
    my ($id, $kingdom, $genome_path) = split /\t/;

    mkdir "$outdir/$id" unless -d "$outdir/$id";

    my $cmd = "$cfg{PROKKA} $genome_path "
            . "--addgenes --centre X --compliant "
            . "--prefix $id --kingdom $kingdom "
            . "--outdir $outdir/$id/prokka";

    system($cmd) == 0 or die "Prokka failed: $id";

    system("ln -sf $outdir/$id/prokka/$id.faa $outdir/$id/$id.pep.fa");
}
close $gl;

# ======================
# Step2: HMM search
# ======================
open $gl, '<', $genome_list or die $!;
while (<$gl>) {
    chomp;
    my ($id) = split /\t/;

    system("$cfg{HMMSEARCH} --cut_ga -o $outdir/$id/QSP.out --tblout $outdir/$id/QSP.out.txt "
         . "--cpu $cfg{CPU} $cfg{HMM_DB} $outdir/$id/$id.pep.fa");
}
close $gl;

# ======================
# Step3: Extract hits
# ======================
open $gl, '<', $genome_list or die $!;
while (<$gl>) {
    chomp;
    my ($id) = split /\t/;

    my %hit;
    open my $in, "<", "$outdir/$id/QSP.out.txt" or next;
    while (<$in>) {
        next if /^#/;
        my ($g) = split;
        $hit{$g} = 1;
    }
    close $in;

    open my $pep, "<", "$outdir/$id/$id.pep.fa" or next;
    open my $out, ">", "$outdir/$id/QSP.pep";

    local $/ = ">";
    <$pep>;
    while (<$pep>) {
        chomp;
        my ($h, @seq) = split /\n/;
        my ($gene) = split /\s+/, $h;
        next unless exists $hit{$gene};
        print $out ">$h\n", join("\n", @seq), "\n";
    }
    close $pep;
    close $out;
}
close $gl;

# ======================
# Step4: Merge AgrD
# ======================
open my $merge, ">", "$outdir/extract.AgrD.fa";
for my $f (glob("$outdir/*/QSP.pep")) {
    my ($id) = (split /\//, $f)[-2];
    open my $in, "<", $f;
    local $/ = ">";
    <$in>;
    while (<$in>) {
        chomp;
        print $merge ">$id\_$_";
    }
    close $in;
}
close $merge;

# ======================
# Step5: Alignment
# ======================
system("$cfg{MAFFT} --maxiterate 1000 --thread $cfg{CPU} --localpair $outdir/extract.AgrD.fa > $outdir/extract.AgrD.mafft.fa");

# ======================
# Step6: Extract AgrD 17aa pro-peptide
# ======================
open IN, "<$outdir/extract.AgrD.mafft.fa";
local $/ = ">";
<IN>;

my (%seq, %Pcount, $total);

while (<IN>) {
    chomp;
    my ($h, $s) = split /\n/, $_, 2;
    $s =~ s/\n//g;
    $seq{$h} = $s;

    my @a = split //, $s;
    for my $i (0..$#a) {
        $Pcount{$i}++ if $a[$i] eq "P";
    }
    $total++;
}
close IN;

# find conserved P position
my $pos;
foreach my $k (sort {$Pcount{$b}<=>$Pcount{$a}} keys %Pcount) {
    if ($Pcount{$k}/$total > 0.95) {
        $pos = $k;
        last;
    }
}

open OUT, ">$outdir/AgrD_17aa.fa";
foreach my $id (keys %seq) {
    my $s = $seq{$id};
    my $sub = substr($s, 0, $pos+1-6);
    $sub =~ s/-//g;
    next if length($sub) < 17;
    my $final = substr($sub, -17);
    print OUT ">$id\n$final\n";
}
close OUT;

print "Done!\nOutputs:\nextract.AgrD.fa\nAgrD_17aa.fa\n";
