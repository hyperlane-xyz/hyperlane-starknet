#!/bin/sh

FILEPATH="crates/contracts/src/fee_token.cairo"
TEMPFILE=$(mktemp)

# writes all but the last 2 lines to the temp file
head -n $(($(wc -l < $FILEPATH) - 2)) $FILEPATH > $TEMPFILE

# writes generated last 2 lines to the temp file
cat <<EOF >> $TEMPFILE
    $FEE_TOKEN.try_into().unwrap()
}
EOF

# overwrite the original file with the temp file
cat $TEMPFILE > $FILEPATH
