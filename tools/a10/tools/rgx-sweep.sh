for r in "0x400 0x480" "0xc00 0xd40" "0x200 0x300" "0x340 0x3e0" "0xf000 0xf080"; do
  set -- $r; o=$(($1)); while [ $o -lt $(($2)) ]; do v=$(devmem $((0x201000000+o)) 32); [ "$v" != "0x00000000" ] && printf "%x=%s\n" $o $v; o=$((o+4)); done
done
