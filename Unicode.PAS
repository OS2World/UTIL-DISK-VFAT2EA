//
// Unicode Unit
// Written by Doodle
//
// If no unicode present, falls back to fake conversion.
//

Unit Unicode;
Interface

{&CDECL+}{&USE32+}

uses OS2Def,OS2Base;
Type UniChar=USHORT;
     pUniChar=^UniChar;
     UConvObject=Pointer;

var Unicode_is_present:Boolean;


Function UniCreateUconvObject(var cpname:UniChar;var uconv_object:UconvObject):ApiRet;
Function UniFreeUconvObject(uconv_object:UconvObject):ApiRet;
Function UniUconvFromUcs(uconv_object:UconvObject; var ucsbuf; var UniCharsleft:word;
                     var outbuf; var outbytesleft:word; var nonidentical:word):ApiRet;
Function UniUconvToUcs(uconv_object:UconvObject; var inbuf; var inBytesLeft:word; var ucsbuf;
                     var uniCharsLeft:word; var nonidentical:word):ApiRet;
Function UniStringLength(UniCharArray:pointer;MaxUniChars:longint):longint;

implementation

type uni_f1=function(cpname:pUniChar;var uconv_object:UconvObject):ApiRet;
type uni_f2=function(uconv_object:UconvObject):ApiRet;
type uni_f3=function(uconv_object:UconvObject; var ucsbuf:pointer; var UniCharsleft:word;
                     var outbuf:pointer; var outbytesleft:word; var nonidentical:word):ApiRet;
type uni_f4=function(uconv_object:UconvObject; var inbuf:pointer; var inBytesLeft:word; var ucsbuf:pointer;
                     var uniCharsLeft:word; var nonidentical:word):ApiRet;


var hmodUCONV:hModule;
    Unicode_Old_Exitproc:pointer;
    UniCreateUconvObject_:Uni_F1;
    UniFreeUconvObject_:Uni_F2;
    UniUconvFromUcs_:Uni_F3;
    UniUconvToUcs_:Uni_F4;

Function UniStringLength(UniCharArray:pointer;MaxUniChars:longint):longint;
begin
  result:=0;
  while (memw[ofs(UniCharArray^)+result*2]<>0) and (result<MaxUniChars) do inc(result);
end;

Function UniCreateUconvObject(var cpname:UniChar;var uconv_object:UconvObject):ApiRet;
begin
  if not Unicode_is_present then result:=no_error else
  begin
    result:=UniCreateUconvObject_(@cpname,uconv_object);
  end;
end;

Function UniFreeUconvObject(uconv_object:UconvObject):ApiRet;
begin
  if not Unicode_is_present then result:=no_error else
  begin
    result:=UniFreeUconvObject_(uconv_object);
  end;
end;

Function UniUconvFromUcs(uconv_object:UconvObject; var ucsbuf; var UniCharsleft:word;
                     var outbuf; var outbytesleft:word; var nonidentical:word):ApiRet;
var p1,p2:pointer;
    w:word;
begin
  if not Unicode_is_present then
  begin
    if UniCharsLeft>outbytesleft then
    begin
      result:=132114;  // Not enought output buffer size
    end else
    begin
      for w:=0 to UniCharsLeft-1 do
      begin
        mem[ofs(outbuf)+w]:=mem[ofs(ucsbuf)+w*2];  // Simply copy the first bytes from the unicodes...
      end;
      dec(outbytesleft,UniCharsLeft);dec(unicharsleft,UniCharsLeft);
      result:=no_error
    end;
  end else
  begin
    p1:=@ucsBuf;p2:=@outbuf;
    result:=UniUconvFromUcs_(uconv_object,p1,UniCharsLeft,p2,outbytesleft,nonidentical);
  end;
end;

Function UniUconvToUcs(uconv_object:UconvObject; var inbuf; var inBytesLeft:word; var ucsbuf;
                     var uniCharsLeft:word; var nonidentical:word):ApiRet;
var p1,p2:pointer;
    w:word;
begin
  if not Unicode_is_present then
  begin
    if inBytesLeft>UniCharsLeft then
    begin
      result:=132114;  // Not enought output buffer size
    end else
    begin
      for w:=0 to inBytesLeft-1 do
      begin
        mem[ofs(ucsbuf)+w*2]:=mem[ofs(inbuf)+w];   // "make unicode": code byte + zero byte = unicode (well.. almost.:) )
        mem[ofs(ucsbuf)+w*2+1]:=0;
      end;
      dec(unicharsleft,inbytesleft);dec(inbytesleft,inbytesleft);
      result:=no_error;
    end;
  end else
  begin
    p1:=@inbuf;p2:=@ucsbuf;
    result:=UniUconvToUcs_(uconv_object,p1,inBytesLeft,p2,uniCharsleft,nonidentical);
  end;
end;




function LoadUCONV:boolean;
var rc:apiret;
begin
  rc:=DosLoadModule ('', 0, 'UCONV.DLL', hmodUCONV);
  if rc=0 then
  begin
    rc:=DosQueryProcAddr (hmodUCONV,
                                0,
                                'UniCreateUconvObject',
                                @UniCreateUconvObject_);
    if rc=0 then
    begin
      rc:=DosQueryProcAddr (hmodUCONV,
                                0,
                                'UniFreeUconvObject',
                                @UniFreeUconvObject_);
      if rc=0 then
      begin
        rc:=DosQueryProcAddr (hmodUCONV,
                                0,
                                'UniUconvFromUcs',
                                @UniUconvFromUCS_);
        if rc=0 then
        begin
          rc:=DosQueryProcAddr (hmodUCONV,
                                0,
                                'UniUconvToUcs',
                                @UniUconvToUCS_);
        end;
      end;
    end;
  end else
    hmodUCONV:=-1;

  if rc=0 then Unicode_is_present:=True else Unicode_is_present:=False;
  LoadUCONV:=(rc=0);
end;

procedure UnLoadUCONV;
var rc:apiret;
begin
  if hmodUCONV<>-1 then
  begin
    rc:=DosFreeModule(hmodUCONV);
    hmodUCONV:=-1;
  end;
end;

procedure Unicode_New_Exitproc;
begin
  exitproc:=Unicode_Old_Exitproc;
  UnLoadUCONV;
end;


begin
  if not LoadUCONV then
  begin
    Writeln('*** Unicode error: Cannot link UCONV.DLL!');
  end;
  if not Unicode_is_present then
  begin
    Writeln('*** No real unicode conversion routines present.');
    writeln('    A fake conversion will be used instead.');
    writeln('    (National characters will be possibly wrong!)');
  end;
  UniCode_Old_Exitproc:=exitproc;
  exitproc:=@Unicode_new_exitproc;
end.
