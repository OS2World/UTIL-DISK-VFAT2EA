/* */
say 'rxCopy 0.99'
say 'Usage: rxcopy <frommask> <topath>'
say
parse value arg(1) with from' 'to
say 'Working with 'from
say 'Copying to 'to

rc = SysFileTree(from,res,'FO')

do i=1 to res.0
 say res.i
 if (POS('EA DATA. SF',res.i)=0)&(POS('WP ROOT. SF',res.i)=0) then do
     rc = SysGetEA(res.i,'.LONGNAME',result.i)
     say delstr(result.i,1,4)
     say 'Copying 'res.i' to 'to''delstr(result.i,1,4)
     'copy 'res.i' 'to'"'delstr(result.i,1,4)'"'
    end
end

