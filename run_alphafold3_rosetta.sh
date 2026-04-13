source af_rosetta_config.txt

PARENT_DIR=$(dirname "$INPUT_DIR")
AF3OUT_DIR="$PARENT_DIR/_af3out"

./alphafold3_structure_prediciton.sh --auto --input_dir $INPUT_DIR --gpu_device 0

./rosetta_interface_analysis.sh $PARENT_DIR $AF3OUT_DIR $ROSETTA_DIR $PROTEIN_ID $ROSETTA_SCRITPS
