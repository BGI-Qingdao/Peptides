PARENT_DIR=$1
AF3OUT_DIR=$2
ROSETTA_DIR=$3
PROTEIN_ID=$4
ROSETTA_SCRITPS=$5

cd $ROSETTA_DIR
## rosetta fast relax
$ROSETTA_SCRITPS/relax.static.linuxgccrelease -out:path:pdb $ROSETTA_DIR -out:path:score $ROSETTA_DIR -s $AF3OUT_DIR/${PROTEIN_ID}.pdb @./general_relax_flags

## rosetta interface analysis
${ROSETTA_SCRITPS}/score_jd2.static.linuxgccrelease -s ${PROTEIN_ID}.pdb -no_optH false -ignore_unrecognized_res -out:pdb
${ROSETTA_SCRITPS}/InterfaceAnalyzer.static.linuxgccrelease -s ${PROTEIN_ID}_0001.pdb -fixedchains AB -interface A_B @$path_option -overwrite
