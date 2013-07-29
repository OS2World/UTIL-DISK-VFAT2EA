{                                                        }
{ Basic Extended Attributes processing unit              }
{ Version 1.0 by Doodle                                  }
{  Thanks for Henk Kelder for example code!              }
{                                                        }

Unit EA;

interface
uses Use32,OS2Def,OS2Base,SysUtils;

Const IgnoreCHKDSK:Boolean=True;  // OS/2 has problems with CHKDSK created
                                  // files CHKDSK.LOG and CHKDSK.OLD.
                                  // After adding EA to these files, every
                                  // process trying to access them will
                                  // hang, and cannot be killed. It's a
                                  // workaround for this bug.

{ Get_ASCII_EA :   Reads an EAT_ASCII type EA of a given file or directory }

Function Get_ASCII_EA(pszName:string;EAname:string):String;

{ Set_ASCII_EA : Writes an EAT_ASCII type EA for a given file or directory }
{   The result is TRUE if successful, FALSE if unsuccessful                }

Function Set_ASCII_EA(pszName:string;EAname:string;EAValue:string):Boolean;


                        { ---- IMPLEMENTATION ---- }
implementation

Type DENA2=FEA2;
     PDENA2=PFEA2;

var bDena:array[0..65535] of byte;  { Working Buffer }

{ ------------------------- EA handling functions ----------------------- }


{ GetEAs : Queries given EAs for a given file or directory }
{   ulDenaCnt : Number of EAs in pDenaBlock                }
{   pDenaBlock : points to GEA2 structure                  }

Function GetEAs(ulDenaCnt:Ulong; pDenaBlock:PDENA2;
                hfFile:HFILE; pszName:string):PFEA2LIST;
var
  ulFEASize : ULong;
  ulGEASize : ULong;
  ulIndex   : ULong;
  EAop      : EAOP2;
  pGea      : PGEA2;
  pDena     : PDENA2;
  rc        : ApiRet;
  ulFSize   : ULong;
  ulGSize   : ULong;
  usDiff    : UShort;

begin
   (*
      Calculate size of needed buffers
   *)
   ulFEASize := sizeof (ULONG);
   ulGEASize := sizeof (ULONG);
   pDena := PDENA2(pDenaBlock);
   for ulIndex := 0 to ulDenaCnt-1 do
   begin
     ulFSize := sizeof (FEA2) + pDena^.cbName + pDena^.cbValue;
     ulGSize := sizeof (GEA2) + pDena^.cbName;

     ulFSize := ulFSize + (4 - (ulFSize mod 4));
     ulFEASize := ulFEASize + ulFSize;

     ulGSize := ulGSize + (4 - (ulGSize mod 4));
     ulGEASize := ulGEASize + ulGSize;

     if (pDena^.oNextEntryOffset=0) then
     begin
       Break;
     end;
     pDena := PDENA2( ulong(pDena) + ulong(pDena^.oNextEntryOffset));
   end;

   (*
      Allocate needed buffers
   *)
   getmem(EAop.fpGEA2List,ulGEASize);
   if (EAop.fpGEA2List=Nil) then
   begin
      Result:=NIL;
      exit;
   end;
   FillChar(EAop.fpGEA2List^, ulGEASize, 0);

   GetMem(EAop.fpFEA2List, ulFEASize);
   if (EAop.fpFEA2List=NIL) then
   begin
      FreeMem(EAop.fpGEA2List);
      result:=Nil;
      exit;
   end;

   FillChar(EAop.fpFEA2List^, ulFEASize, 0);


   (*
      Build the PGEALIST
   *)
   EAop.fpGEA2List^.cbList := ulGEASize;
   EAop.fpFEA2List^.cbList := ulFEASize;

   pDena := PDENA2(pDenaBlock);
   pGea  := @(EAop.fpGEA2List^.list);
   for ulIndex := 0 to ulDenaCnt-1 do
   begin

      pGea^.cbName := pDena^.cbName;
      move(pDena^.szName, pGea^.szName, pDena^.cbName+1);

      if (ulIndex < ulDenaCnt - 1) then
         pGea^.oNextEntryOffset := sizeof (GEA2) + pDena^.cbName
      else
         pGea^.oNextEntryOffset := 0;

      usDiff := pGea^.oNextEntryOffset mod 4;
      if (usDiff<>0) then
         pGea^.oNextEntryOffset :=pGea^.oNextEntryOffset + (4 - usDiff);

      pGea  := PGEA2(  ulong(pGea) + pGea^.oNextEntryOffset);
      pDena := PDENA2( ulong(pDena) + pDena^.oNextEntryOffset);
   end;

   (*

     Query EAs

   *)

   if (hfFile<>0) then
   begin
      rc := DosQueryFileInfo(hfFile,
         FIL_QUERYEASFROMLIST,
         EAop,
         sizeof(EAop));
   end else
   begin
         pszName:=pszName+#0;
         rc := DosQueryPathInfo(@pszName[1],
         FIL_QUERYEASFROMLIST,
         EAop,
         sizeof(EAop));
         SetLength(pszName,length(pszName)-1);
   end;

   if (rc<>0) then
   begin
     freemem(EAop.fpGEA2List);
     freemem(EAop.fpFEA2List);
     result:=Nil;
     exit;
   end;

   freemem(EAop.fpGEA2List);
   result:=EAOp.fpFEA2List;
end;

{ GetDirEA : Reads all EAs for a directory (or file) using   }
{            its path, not filehandle.                       }
{            To query, it uses GetEAs.                       }

Function GetDirEA(pszName:string):PFEA2LIST;
var
  ulOrd     : ULong;
  ulDenaCnt : ULong;
  rc        : ApiRet;

begin
   ulOrd := 1;
   ulDenaCnt := -1;

   FillChar(bDena, sizeof(bDena), 0);

   pszName:=pszName+#0;

   rc := DosEnumAttribute(ENUMEA_REFTYPE_PATH,
      @pszName[1],
      ulOrd,
      bDena,
      sizeof(bDena),
      ulDenaCnt,
      ENUMEA_LEVEL_NO_VALUE);

   SetLength(pszName,length(pszName)-1);

   if (rc<>no_Error) then
   begin
     Result:=NIL;
     exit;
   end;
   if (ulDenaCnt=0) then
   begin
     Result:=Nil;
     exit;
   end;
   result:=GetEAs(ulDenaCnt, PDENA2(@bDena), 0, pszName);
end;

{ GetEA : Reads all EAs for a directory or file.             }
{   Firstly, it tries to open it as a file. If it is unsuc-  }
{   cessful, then calls GetDirEA to make the job.            }
{   If Successful, then Enumerates and Queries EAs by handle.}

Function GetEA(pszName:String):PFEA2LIST;
var
  ulOrd     : ULong;
  ulDenaCnt : ULong;
  rc        : ApiRet;
  ulActionTaken : ULong;
  hfFile    : HFile;
  _pFea2List : PFEA2LIST;

begin
   pszName:=pszName+#0;
   rc := DosOpen(@pszName[1], hfFile, ulActionTaken,
      0, (* file size *)
      0, (* file attributes *)
      OPEN_ACTION_FAIL_IF_NEW or OPEN_ACTION_OPEN_IF_EXISTS,
      OPEN_SHARE_DENYNONE or OPEN_ACCESS_READONLY,
      NIL);
   SetLength(pszName,length(pszName)-1);
   if (rc<>0) then
   begin
     result:=GetDirEA(pszName);
     exit;
   end;

   (*
      Now query ea's
   *)

   ulOrd := 1;
   ulDenaCnt := -1;

   FillChar(bDena, sizeof(bDena), 0);

   rc := DosEnumAttribute(ENUMEA_REFTYPE_FHANDLE,
      @hfFile,
      ulOrd,
      bDena,
      sizeof(bDena),
      ulDenaCnt,
      ENUMEA_LEVEL_NO_VALUE);

   if (rc<>0) then
   begin
     DosClose(hfFile);
     result:=Nil;
     exit;
   end;
   if (ulDenaCnt=0) then
   begin
     DosClose(hfFile);
     Result:=Nil;
   end;
   _pFea2List := GetEAs(ulDenaCnt, PDENA2(@bDena), hfFile, pszName);
   DosClose(hfFile);
   result:=_pFea2List;
end;

{ WriteEA: Writes *ONE* EA given in pFEA to a file }
{          or directory.                           }
{          First, tries to do it by file handle.   }
{          If it cannot, tries to do it by path.   }

Function WriteEA(pszName:String; pFEA:pFEA2):Boolean;
var
  eaop       : EAOP2;
  pFeaList   : PFEA2LIST;
  ulListSize : ULong;
  rc         : ApiRet;
  hfFile     : hFILE;
  ulActionTaken:ULong;
  Temp       : String;
  l:longint;

begin
   result:=True;

   ulListSize := sizeof (FEA2LIST) +
      pFea^.cbName +
      pFea^.cbValue;

   getmem(pFeaList,ulListSize);
   if (pFeaList=Nil) then
   begin
     Result:=False;
     exit;
   end;

   move(pFEA^, pFeaList^.list, sizeof (FEA2) +
      pFea^.cbName +
      pFea^.cbValue);
   pFeaList^.cbList := ulListSize;

   FillChar(eaop, sizeof(eaop),0);
   eaop.fpFEA2List := pFeaList;

   pszName:=pszName+#0;
   rc := DosOpen(@pszName[1], hfFile, ulActionTaken,
      0, (* file size *)
      0, (* file attributes *)
      OPEN_ACTION_FAIL_IF_NEW or OPEN_ACTION_OPEN_IF_EXISTS,
      OPEN_SHARE_DENYNONE or OPEN_ACCESS_READWRITE,
      NIL);
   SetLength(pszName,length(pszName)-1);
   if (rc<>0) then
   begin   { Treat as directory, use DosSetPathInfo! }
     pszName:=pszName+#0;
     rc := DosSetPathInfo(@pszName[1],
        FIL_QUERYEASIZE,
        eaop,
        sizeof(eaop),
        DSPI_WRTTHRU);
     SetLength(pszName,length(pszName)-1);

     if (rc<>0) then
     begin
       Result:=false;
     end;
   end else
   begin { Could open, use as file!}

     { Check for CHKDSK.LOG or .OLD file!     }
     { If it's some of them, skip it!         }
     { See IgnoreCHKDSK constant declaration. }
     if IgnoreCHKDSK and (Length(pszName)>1) then
     begin
       temp:='';
       for l:=1 to length(pszName) do temp:=temp+upcase(pszName[l]);

       if (temp='\CHKDSK.LOG') or
          (temp='\CHKDSK.OLD') or
          (copy(temp,2,length(temp))=':\CHKDSK.LOG') or
          (copy(temp,2,length(temp))=':\CHKDSK.OLD') then
       begin
         DosClose(hfFile);
         freemem(pFeaList);
         result:=True;      { Fake Successful }
         exit;
       end;
       { Not CHKDSK.LOG or OLD, can continue }
     end;

     rc := DosSetFileInfo(hfFile,
        FIL_QUERYEASIZE,
        eaop,
        sizeof(eaop));

     if (rc<>0) then
     begin
       Result:=false;
     end;
     DosClose(hfFile);
   end;
   freemem(pFeaList);
end;

{ GetASCIIByName : Tries to get the value of an ASCII EA named by }
{      'name'. pFEAData points to list of FEAs.                   }
{      If successful, returns the value as a string. If unsucces- }
{      ful, returns an empty string.                              }

Function GetASCIIByName(name:string;pFeaData:PFEA2LIST):string;
var
  sIndex:SHORTINT;
  pValue:PBYTE;
  szEAType:array[0..99] of byte;
  usEAType,
  usEASize:UShort;
  fProcess:Boolean;
  Incrementer:longint;

  pfea2base:pFEA2;
  eaname:string;

begin
  result:='';
  if pFEAData=NIL then exit;

  pfea2base:=@pFeaData^.List[0];

  repeat
    pValue := pbyte(ulong(@pFea2base^.szName) + ulong(pFea2base^.cbName + 1));

    usEAType := pUSHORT(pValue)^;

    eaName:=strpas(pchar(@pFEA2Base^.szName));

    if (usEAType=EAT_ASCII) and (eaName=Name) then
    begin
      pValue := pBYTE(ulong(pvalue)+sizeof (USHORT));

      usEASize  := pUSHORT(pvalue)^;

      SetLength(result,usEASize);
      move(pchar(ulong(pvalue)+2)^,result[1],usEASize);
    end;
    Incrementer:=pFEA2Base^.oNextEntryOffset;
    pFEA2Base:=pFEA2(ulong(pFEA2Base)+pFEA2Base^.oNextEntryOffset);
  until (Incrementer=0) or (result<>'');
end;

{ --- Get_ASCII_EA --- }
{  Returns the value of an ASCII type EA for file 'pszName', or }
{  NULL if no such EA found.                                    }


Function Get_ASCII_EA(pszName:string;EAname:string):String;
var FEA2List:pFEA2List;
    rc:integer;
begin
  FEA2List:=GetEA(pszName);
  if FEA2List=NIL then
  begin
    result:='';
    exit;
  end;
  result:=GetASCIIByName(EAname,FEA2List);
  dispose(FEA2List);
end;

{ --- Set_ASCII_EA --- }
{  Sets the value of an ASCII type EA for file 'pszName'. }
{  Returns TRUE if successful, FALSE otherwise.           }

Function Set_ASCII_EA(pszName:string;EAname:string;EAValue:string):Boolean;
var pfea:pFEA2;
    pwork:ulong;
begin
  getmem(pfea,sizeof(fea2)+length(eaname)+1+2+2+length(eavalue)+1);
  with pfea^ do
  begin
    oNextEntryOffset:=0;
    fea:=0;
    cbname:=length(eaname);
    cbValue:=2+2+length(EAValue);
  end;

  EAName:=EAName+#0;
  move(EAName[1],pfea^.szName,length(eaname));
  setlength(EAName,length(EAName)-1);

  pwork:=ulong(@pfea^.szName)+length(eaname)+1;
  pUSHORT(pwork)^:=EAT_ASCII;
  pwork:=pwork+2;
  pUSHORT(pwork)^:=length(EAValue);
  pwork:=pwork+2;

  eavalue:=eavalue+#0;
  move(EAValue[1],pointer(pwork)^,length(eavalue));
  setlength(EAValue, length(EAValue)-1);

  result:=WriteEA(pszName,pfea);
  freemem(pfea);
end;

end.

