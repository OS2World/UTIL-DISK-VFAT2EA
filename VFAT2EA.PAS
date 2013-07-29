//
// VFAT2EA v1.5
// Written by Doodle and OAX
//
Program VFAT_2_LONGNAME_EA;
{&PMTYPE VIO}                 // Create a VIO application
{$M 163840}                   // Use 160Kbytes stack
{$H-}                         // Don't use huge strings, they are buggy in Virtual Pascal
{&use32-}                     // Use 32bits variables only when I say so (when Use32 unit is included)

                              // Use the following units:
uses OS2Def,OS2Base,          //  Basic OS/2 defines and functions
     Use32,                   //  Use 32bits types
     SysUtils,                //  Some useful functions are in SysUtils,
     VPUtils,                 //  some in VPUtils
     EA,                      //  The EA-handling functions are in this unit
     Unicode,                 //  And we will need unicode conversion too
     forDBCS;                 //  DBCS functions.

Const Version_String='v1.5';
Const tNOFAT=0;               // Partition types: Not a FAT partition
      tFAT16=1;               //                  FAT16 partition
      tFAT12=2;               //                  FAT12 partition
      tFATDetect=3;           //                  Let VFAT2EA decide if FAT12 or FAT16

                                 // Type definitions:
type pFSEntryType=^FSEntryType;  // File System Entry type, two in one:
     FSEntryType=record
       case byte of
        0: (                                  // Normal entry
            FileName:array[0..7] of char;
            extension:array[0..2] of char;
            Attrib1:Byte;
            SmallLetters:Byte;
            CreationTime_Hundreds:Byte;
            CreationTime:SmallWord;
            CreationDate:SmallWord;
            LastAccessDate:SmallWord;
            Reserved1:SmallWord;
            LastModificationTime:SmallWord;
            LastModificationDate:SmallWord;
            StartCluster:SmallWord;
            Length:ULong;
            );
        1: (                                  // LFN entry
            Counter:Byte;
            First5:array[0..4] of SmallWord;
            Attrib2:Byte;
            Reserved2:byte;
            Checksum:byte;
            Second6:array[0..5] of SmallWord;
            StartCluster_0:SmallWord;
            Third2:array[0..1] of SmallWord;
           );
      end;

type  pEAList_Type=^EAList_Type; // Linked list type to store .LONGNAME EAs for files:
      EAList_Type=record
        PathName,
        LongName:String[255];
        Next:pEAList_Type;
      end;

type  pFSEntryList_Type=^FSEntryList_Type; // Type definition for a tree to store directory structure
      FSEntryList_Type=record
        Entry:FSEntryType;
        fname:string;

        Next:pFSEntryList_Type;
        Sub:pFSEntryList_Type;
      end;

// Type definitions for Unicode conversion (buffer types):

type CharArray=array[0..511] of char;         // (512 bytes)
     pCharArray=^CharArray;
     UniCharArray=array[0..511] of SmallWord; // (1024 bytes) 16 bits
     pUniCharArray=^UniCharArray;
     DataArray=Array[0..4096] of byte;        // (4097 bytes)
     pDataArray=^DataArray;


type pListType=^ListType;                     // General list of entries:
     ListType=record
       path:string[255];
       shname:string[12];
       LongName:String[255];
       StartCluster:SmallWord;
       Attrib:byte;
       Next:pListType;
     end;

type BPB_Type=record                          // BIOS Parameter Block

       BytesPerSector:SmallWord;              // 0Bh            00,01
       SectorsPerCluster:Byte;                // 0Dh            02
       ReservedSectors:SmallWord;             // 0Eh            03,04
       NumberOfFATs:Byte;                     // 10h            05
       RootEntries:SmallWord;                 // 11h            06,07
       NumberOfSectors:SmallWord;             // 13h            08,09
       MediaDescriptor:Byte;                  // 15h            0A
       SectorsPerFAT:SmallWord;               // 16h            0B,0C
       SectorsPerHead:SmallWord;              // 18h            0D,0E
       HeadsPerCylinder:SmallWord;            // 1Ah            0F,10
       NumHiddenSectors:Longint;              // 1Ch            11,12,13,14
       NumberOfSectorsHuge:Longint;           // 20h            15,16,17,18
       // The others are not required for us
       Others:array[$19..$1E] of byte;
     end;


var hF:hFile;               // File handle used to open a drive in direct access mode
    action:ulong;           // The action taken at opening the drive will be reported here by DosOpen
    rc:apiret;              // Result of the API calls
    sign:string[8];         // The signature of partition, eg. 'FAT12   '
    os2reported_sign:string;// If we cannot decide, we ask OS/2 for partition type. Its result will be here.
    Drive,ToDoPath:string;  // The command-line parameters 'Drive' and 'Path' will come here.

    EAList:pEAList_Type;    // List of EAs for files
    DirStruct:pFSEntryList_Type; // The Directory tree

    DevName:pchar;          // C-style string used to open the drive with DosOpen

    BPB:BPB_Type;           // The BPB will be read into this variable
    RootStart,              // The logical sector number where the root directory starts
    ClustersStart:ULong;    // The logical sector number where the clusters start

    FAT:Pointer;            // The FAT will be read into this
    FATSize:ULong;          // The size of FAT in memory
    NumberOfSectors,
    NumberOfClusters:ULong;
    EntriesPerSector:Word;

    FatType:Byte;           // Type of FAT (see t* constants!)
                            // User settable variables, set by command line parameters:
    ForceFAT:Boolean;
    QueryOnly,
    NoLock:boolean;
    Dots:Boolean;
    ShowDriveParams:Boolean;
    ShowEAErrors:Boolean;
    EA2VFAT:Boolean;

    FloppyMode:Boolean;     // True if the program works with a floppy, false if with a HDD

    Data:array[0..4096] of byte; // Data area, used for example to read bootsector into this.
    t:longint;                   // General purpose temp. variable
    Param:String;                // UpStr'd command line parameter

    MainHead,Dele:pListType;

    FirstMemUsed:ULong;     // Used for memory-leak detection. Stores the used memory at the
                            // start of the app., and compared to the used memory at the app termination.

    GetDeviceParams_CommandInfoByte:Byte; // Some versions before, it was possible to change the
                            // CommandInfo byte for GetDeviceParams call, to check different results.
                            // Now it's always 1, but kept here for easy changing later, if needed.

    VFAT2EA_Old_Exitproc:Pointer; // Old exitproc



//////////////////////////////////////////////////////////////////////////
//
// ReadSector
//
// Reads sector number ADR into buffer pointed by DATA, a maximum
// of DATALENMAX bytes.
// Assumes that the drive has been opened, and the handle is in HF.
//
Procedure ReadSector(adr:longint;var Data:Pointer;DataLenMax:ulong);
type ParamsType=array[0..4095] of byte;
var Params:^ParamsType;
    sect,head,cyl:SmallWord;
    parmlenmax:ulong;
    t:ulong;
begin
  new(Params);     // Allocate memory for command parameter

  t:=(adr+BPB.NumHiddenSectors) div BPB.SectorsPerHead;           // Count
  sect:=((adr+BPB.NumHiddenSectors) mod BPB.SectorsPerHead) +1;   //       Sector
  head:=t mod BPB.HeadsPerCylinder;                               //       Head
  cyl:=t div BPB.HeadsPerCylinder;                                //       Cylinder

  parmlenmax:=13;                                                 // Prepare DSK_READTRACK command parameter
  fillchar(params^,sizeof(params^),0);
  params^[0]:=0;                             // command info
  params^[1]:=lo(head);params^[2]:=hi(head); // head
  params^[3]:=lo(cyl);params^[4]:=hi(cyl);   // cylinder
  params^[5]:=lo(sect);params^[6]:=hi(sect); // first sect.
  params^[7]:=1;params^[8]:=0;               // Num of sectors

  for t:=0 to BPB.SectorsPerHead do
  begin
    params^[9+t*4]:=lo(t);params^[10+t*4]:=hi(t);                                    // sector number
    params^[11+t*4]:=lo(BPB.BytesPerSector);params^[12+t*4]:=hi(BPB.BytesPerSector); // sector size
  end;
                                                  // Now that the command parameter is prepared,
                                                  // execute the command to read the sector!
  rc:=DosDevIOCTL(hf,IOCTL_DISK,DSK_READTRACK,params,parmlenmax,@parmlenmax,data,datalenmax,@datalenmax);
  if rc<>0 then writeln('DosRead Error @ReadSector: rc=',rc);
  Dispose(Params); // Deallocate memory used as command parameter
end;

//////////////////////////////////////////////////////////////////////////
//
// WriteSector
//
// Writes buffer pointer by DATA with size DATALENMAX into
// sector number ADR.
// Assumes that the drive has been opened, and the handle is in HF.
//
Procedure WriteSector(adr:longint;var Data:Pointer;DataLenMax:ulong);
type ParamsType=array[0..4095] of byte;
var Params:^ParamsType;
    sect,head,cyl:SmallWord;
    parmlenmax:ulong;

    t:ulong;
begin
  new(Params);

  t:=(adr+BPB.NumHiddenSectors) div BPB.SectorsPerHead;          // Calculate
  sect:=((adr+BPB.NumHiddenSectors) mod BPB.SectorsPerHead) +1;  //   Sector
  head:=t mod BPB.HeadsPerCylinder;                              //   Head
  cyl:=t div BPB.HeadsPerCylinder;                               //   Cylinder

  parmlenmax:=13;                                                // Prepare command parameter
  fillchar(params^,sizeof(params^),0);
  params^[0]:=0;                             // command info
  params^[1]:=lo(head);params^[2]:=hi(head); // head
  params^[3]:=lo(cyl);params^[4]:=hi(cyl);   // cylinder
  params^[5]:=lo(sect);params^[6]:=hi(sect); // first sect.
  params^[7]:=1;params^[8]:=0;               // Num of sectors

  for t:=0 to BPB.SectorsPerHead do
  begin
    params^[9+t*4]:=lo(t);params^[10+t*4]:=hi(t);                                    // sector number
    params^[11+t*4]:=lo(BPB.BytesPerSector);params^[12+t*4]:=hi(BPB.BytesPerSector); // sector size
  end;
                                                                  // Execute command
  rc:=DosDevIOCTL(hf,IOCTL_DISK,DSK_WRITETRACK,params,parmlenmax,@parmlenmax,data,datalenmax,@datalenmax);
  if rc<>0 then writeln('DosWrite Error @WriteSector: rc=',rc);
  Dispose(Params);
end;

//////////////////////////////////////////////////////////////////////////
//
// ReadDirect
//
// The same as ReadSector, but uses CHS addressing instead of logical
// sector number.
// Assumes that the drive has been opened, and the handle is in HF.
//
Procedure ReadDirect(Cyl,Head,Sect:SmallWord;var Data;DataLenMax:ULong);
type ParamsType=array[0..4095] of byte;
var Params:^ParamsType;
    t,parmlenmax:ulong;
begin
  new(Params);
  parmlenmax:=17;                            // Prepare command parameter
  fillchar(params^,sizeof(params^),0);
  fillchar(data,sizeof(data),0);
  params^[0]:=0;                             // command info
  params^[1]:=lo(head);params^[2]:=hi(head); // head
  params^[3]:=lo(cyl);params^[4]:=hi(cyl);   // cylinder
  params^[5]:=lo(sect);params^[6]:=hi(sect); // first sect.
  params^[7]:=1;params^[8]:=0;               // Num of sectors

  for t:=0 to BPB.SectorsPerHead do
  begin
    params^[9+t*4]:=lo(t);params^[10+t*4]:=hi(t);                                    // sector number
    params^[11+t*4]:=lo(BPB.BytesPerSector);params^[12+t*4]:=hi(BPB.BytesPerSector); // sector size
  end;
                                             // Execute command
  rc:=DosDevIOCTL(hf,IOCTL_DISK,DSK_READTRACK,params,parmlenmax,@parmlenmax,@data,datalenmax,@datalenmax);
  if rc<>0 then writeln('DosRead Error @ReadDirect: rc=',rc);
  dispose(Params);
end;

//////////////////////////////////////////////////////////////////////////
//
// Unicode2PChar
//
// Converts unicode long filename to simple C-style string.
//
procedure Unicode2PChar(UniLongName:pUniCharArray;LongName:pCharArray);
var name:UniChar;
    UCO:UconvObject;
    rc:apiret;
    UniCharsLeft,OutBytesLeft,NonIdentical:word;
begin
  name:=0;                             // empty unicode string
  rc:=UniCreateUconvObject(name,UCO);  // Create conversion object: Current codepage<->Unicode
  if rc=no_error then
  begin                                // If the object has been created, use it to convert from unicode!
    outbytesleft:=512;
    UniCharsLeft:=UniStringLength(UniLongName,512);
    Nonidentical:=0;
    rc:=UniUconvFromUcs(UCO,UniLongName^,UniCharsLeft,LongName^,OutBytesLeft,nonidentical);
    if rc<>0 then writeln('*** Error converting from unicode string, rc=',rc);
  end else
  begin
    writeln('*** Error creating Unicode convertation object!');
  end;
  rc:=UniFreeUconvObject(UCO);         // Destroy conversion object
end;

//////////////////////////////////////////////////////////////////////////
//
// PChar2Unicode
//
// Converts simple C-style string to unicode.
//
procedure PChar2Unicode(LongName:pCharArray;UniLongName:pUniCharArray);
var name:UniChar;
    UCO:UconvObject;
    rc:apiret;
    UniCharsLeft,inBytesLeft,NonIdentical:word;
begin
  name:=0;                            // empty unicode string
  rc:=UniCreateUconvObject(name,UCO); // Create conversion object: Current codepage<->Unicode
  if rc=no_error then
  begin
    inbytesleft:=strlen(pchar(LongName));
    UniCharsLeft:=512;
    Nonidentical:=0;
    rc:=UniUconvToUcs(UCO,LongName^,inBytesLeft,UniLongName^,UniCharsLeft,nonidentical);
    if rc<>0 then writeln('*** Error converting to unicode string, rc=',rc);
  end else
  begin
    writeln('*** Error creating Unicode convertation object!');
  end;
  rc:=UniFreeUconvObject(UCO);        // Destroy conversion object
end;

//////////////////////////////////////////////////////////////////////////
//
// Count_Checksum
//
// Calculates checksum value from File System Entry
//
function Count_Checksum(Entry:FSEntryType):byte;
var sum:byte;
    i:byte;
begin
  {$R-}
  sum:=0;
  for i:=0 to 10 do
    if i<=7 then sum:=byte(((sum and 1) shl 7) or ((sum and $FE)shr 1))+byte(Entry.FileName[i]) else
                 sum:=byte(((sum and 1) shl 7) or ((sum and $FE)shr 1))+byte(Entry.Extension[i-8]);
  result:=sum;
  {$R+}
end;

//////////////////////////////////////////////////////////////////////////
//
// UpStr
//
// Creates an uppercased string.
// Works with DBCS, and also with SBCS / Nationalcharacters!
//
function UpStr(s:string):string;
var b:byte;
begin
  if uchDBCSInfo[0] = #0 then begin     // (OAX) check SBCS/DBCS
   UpStr := AnsiUpperCase(s);
  end else begin
   for b := 1 to length(s) do
    if isDBCS1stByte(s[b]) = True then  // (OAX) If this byte is a DBCS1thByte then
      b := (b + 1)                      // (OAX) next byte is a DBCS2ndByte. Skip it.
    else                                // (OAX)
      s[b] := upcase(s[b]);
   UpStr := s;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// HeadOf
//
// Returns true if the string SECOND if the head of the string FIRST
//
Function HeadOf(First,Second:String):Boolean;
begin
  First:=UpStr(First);         // Upcase the strings
  Second:=UpStr(Second);
  if length(First)<length(Second) then
  begin                        // If the second is longer, it cannot be the head of first!
    HeadOf:=False;
    exit;
  end;
  First[0]:=Second[0];         // Make them equally long, and check if they are equal!
  HeadOf:=First=Second;
end;

//////////////////////////////////////////////////////////////////////////
//
// NextClusterFromFAT
//
// Checks which cluster is the next in the chain after the cluster CL in
// the File Allocation Table.
//
Function NextClusterFromFat(cl:Longint):Longint;
var modulo:byte;
    next:Longint;
begin
  Next:=-1;
  if (cl<0) or                                    // Check FAT limits!
     ((FatType=tFAT12) and (round(cl*1.5)>FatSize)) or
     ((FatType=tFAT16) and (round(cl*2)>FatSize)) then
  begin
    NextClusterFromFat:=-1;exit;                  // Out of FAT!
  end;

  if FatType=tFAT12 then                          // If it's FAT12:
  begin
    modulo:=(cl*3) mod 2;
    cl:=(cl*3) div 2;
    next:=memw[ofs(FAT^)+cl];
    if modulo=0 then next:=next and $0FFF else
                     next:=next shr 4;
    if hi(Next)=$0F then next:=next or $FFFFFF00; // convert to 32bits
  end else
  if FatType=tFAT16 then                          // If it's FAT16:
  begin
    cl:=cl*2;
    next:=System.SmallInt(memw[ofs(FAT^)+cl]);
  end;
  NextClusterFromFAT:=Next;                       // Set the result
end;

//////////////////////////////////////////////////////////////////////////
//
// FirstFreeFATEntry
//
// Returns the first cluster number (or -1) which looks to be free according
// to the File Allocation Table.
//
Function FirstFreeFATEntry(SkipThis:Longint):Longint;
var l,maxl:longint;
begin
  l:=2;
  // Calculate max cluster number:
  if FatType=tFAT12 then maxl:=(fatsize*2) div 3 else // FAT12
                         maxl:=fatsize div 2;         // FAT16

  // Now check FAT entry for every cluster number, until we find an empty slot!
  while l<=maxL do
  begin
    if (NextClusterFromFAT(l)=0) {and (l<>SkipThis) }then
    begin
      result:=l;exit;
    end;
    inc(l);
  end;
  result:=-1;
end;

//////////////////////////////////////////////////////////////////////////
//
// SetFATEntry
//
// Sets the cluster number CL to DATA in FAT
//
Procedure SetFATEntry(cl:Longint;Data:SmallWord);
var modulo:byte;
    next:SmallWord;
begin
  if (cl<0) or
     ((FatType=tFAT12) and (round(cl*1.5)>FatSize)) or
     ((FatType=tFAT16) and (round(cl*2)>FatSize)) then
  begin
    Writeln('*** Error: Bad number @SetFATEntry: ',cl,' ***');
    exit; // out of FAT
  end;
  if FatType=tFAT12 then
  begin
    Data:=Data and $0FFF;
    cl:=cl and $0FFF;
    modulo:=(cl*3) mod 2;
    cl:=(cl*3) div 2;
    next:=memw[ofs(FAT^)+cl];

    if modulo=0 then next:=(next and $F000) or Data else
                     next:=(Data shl 4) or (Next and $0F);
    memw[ofs(FAT^)+cl]:=Next;
  end else
  if FatType=tFAT16 then
  begin
    cl:=cl*2;
    memw[ofs(FAT^)+cl]:=Data;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// AppendToList
//
// Appends the new element NW into list pointed by its head in HEAD
//
Procedure AppendToList(var head,nw:pFSEntryList_Type);
var seged:pFSEntryList_Type;
begin
  if head=nil then head:=nw else
  begin
    seged:=head;
    while seged^.next<>Nil do seged:=seged^.next;
    seged^.next:=nw;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Store_Longname_in_EALIST
//
// Stores that a .LONGNAME EA should belong to a file.
// Stores only if the longname is not an empty string, and if the list
// doesn't contain this ea yet.
//
procedure Store_Longname_in_EALIST(path:string;LongName:pointer);
var seged,uj:pEAList_Type;
begin
  if strcomp(pchar(LongName),'')<>0 then
  begin // Store this longname if not already stored because of being in an OS/2 EA...
    seged:=EAList;
    while (seged<>Nil) and (seged^.pathname<>path) do seged:=seged^.next;
    if seged=Nil then
    begin // Not stored as a .LONGNAME EA yet...
      writeln(' New VFAT-LFN : ',path,' -> ',pchar(LongName));
      new(uj);
      uj^.next:=EAList;
      uj^.pathname:=path;
      uj^.longname:=strpas(longname);
      EAList:=uj;
    end;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Read_Sector
//
// Processes sector SECTOR containing file-system entries, and builds the
// directory structure from it. Calls itself recursively for folders.
//
procedure Read_Sector(sector:ulong; Path:String; Cluster:LongInt; var Head:pFSEntryList_Type);
var b,a:byte;
    FSEntry:pFSEntryType;
    shname:String[12];
    ext:string[3];
    LongName:pCharArray;
    UniLongName:pUniCharArray;
    Checksum_in_LFN:byte;
    Data:pDataArray;
    uj:pFSEntryList_Type;
    LastEntryFound:boolean;
    SubSectorEntry:Byte;      // Actual entry in currently readed sector
    SectorNum:Word;           // Actual Sector number in current cluster
    NextCluster:LongInt;
begin
  new(FSEntry);
  new(LongName);
  new(UniLongName);
  new(Data);
  LastEntryFound:=False;
  SubSectorEntry:=0;
  ReadSector(Sector,pointer(Data),4096); // Read RAW sector into memory
  SectorNum:=1;
  NextCluster:=NextClusterFromFAT(Cluster);

  FillChar(UniLongName^,Sizeof(UniLongName^),0);
  while (not LastEntryFound) do
  begin
    move(Data^[SubSectorEntry*32],FSEntry^,32);  // Check FS entries one by one:
    if FSEntry^.Counter=0 then
    begin
      LastEntryFound:=True;
      break;
    end;
    with FSEntry^ do
    begin
      if (Attrib2=$0f) and (StartCluster_0=0) then
      begin  // LFN Record : store unicode longname in UniLongName

        for a:=0 to 4 do
            UniLongName^[(Counter and 31 -1)*13+a]:=First5[a];
        for a:=0 to 5 do
            UniLongName^[(Counter and 31 -1)*13+5+a]:=Second6[a];
        for a:=0 to 1 do
            UniLongName^[(Counter and 31 -1)*13+11+a]:=Third2[a];
        Checksum_in_LFN:=Checksum;

      end else
      begin  // Normal Record : store short name in SHNAME
        if (FileName[0]<>chr($E5)) then // if Not Deleted
        begin
          shname:='';ext:='';
          for a:=0 to 7 do
            if (FileName[a]<>' ') then
              shname:=shname+FileName[a];
          for a:=0 to 2 do
            if (Extension[a]<>' ') then
              ext:=ext+Extension[a];

          if ext<>'' then shname:=shname+'.'+ext;

          fillchar(Longname^,sizeof(Longname^),0);
          if Checksum_in_LFN=Count_Checksum(fsentry^) then // if this LFN entry belongs to this short filename, then
          begin
            Unicode2PChar(UniLongName,LongName);             // Convert unicode long filename to simple string,
            Store_Longname_in_EALIST(path+shname,LongName);  // and store it in EALIST as a to-do .LONGNAME EA
          end;

          new(uj);                                         // Append this entry into Directory tree
          uj^.next:=Nil;
          uj^.sub:=Nil;
          uj^.Entry:=FSEntry^;
          uj^.fname:=shname;
          AppendToList(Head,uj);
        end;// else writeln(' ----- Deleted');
        fillchar(UniLongName^,sizeof(UniLongName^),0);     // Set longname:='', because it was a normal record,
                                                           // so the collection of LFN chunks should be restarted.
      end;
    end; // of With FSEntry^ do

    inc(SubSectorEntry); // Next Entry!
    // Do we have to read next sector for the next dorectory entry?
    if (SubSectorEntry=EntriesPerSector) then               // 0..15: 16 entries in one sector
    begin  // Read Next sector
      SubSectorEntry:=0;
      inc(SectorNum);
      if SectorNum<=BPB.SectorsPerCluster then inc(Sector) else
      begin
        if NextCluster<0 then
        begin   // It was the last cluster!
          LastEntryFound:=True;
        end else
        begin
          SectorNum:=1;
          Cluster:=NextCluster;
          if Cluster<-8 then LastEntryFound:=True else
          begin
            NextCluster:=NextClusterFromFAT(Cluster);
            Sector:=(Cluster-2)*BPB.SectorsPerCluster + ClustersStart;
          end;
        end;
      end;
      if not LastEntryFound then
        ReadSector(Sector,pointer(Data),4096);
    end;
  end;

  // Look for sub-directories

  uj:=head;
  while uj<>Nil do
  begin

    if uj^.Entry.Attrib1 and 16=16 then
    begin // A Directory!
      if (uj^.fname<>'.') and (uj^.fname<>'..') then
        Read_Sector((uj^.Entry.StartCluster-2)*BPB.SectorsPerCluster + ClustersStart
                    ,Path+uj^.fname+'\',uj^.Entry.StartCluster,uj^.sub);
    end;
    uj:=uj^.next;
  end;

  Dispose(Data);
  Dispose(UniLongname);
  Dispose(LongName);
  Dispose(FSEntry);
end;

//////////////////////////////////////////////////////////////////////////
//
// Read_RootSector
//
// The same as Read_Sector, but it works with the Root directory, that needs
// some special things.
//
procedure Read_RootSector(sector:ulong;Path:String;NumOfDirEntries:Word;var Head:pFSEntryList_Type);
var b,a:byte;
    FSEntry:pFSEntryType;
    shname:String[12];
    ext:string[3];
    LongName:pCharArray;
    UniLongName:pUniCharArray;
    Checksum_in_LFN:byte;
    Data:pDataArray;
    uj:pFSEntryList_Type;
    LastEntryFound:boolean;
    EntryNum:ULong;           // Number of actual directory entry
    SubSectorEntry:Byte;      // Actual entry in currently readed sector
begin
  new(FSEntry);
  new(LongName);
  new(UniLongName);
  new(Data);
  LastEntryFound:=False;
  EntryNum:=0;
  SubSectorEntry:=0;
  ReadSector(Sector,pointer(Data),4096);
  FillChar(UniLongName^,Sizeof(UniLongName^),0);

  while (not LastEntryFound) and (EntryNum<NumOfDirEntries) do
  begin
    move(Data^[SubSectorEntry*32],FSEntry^,32);
    if FSEntry^.Counter=0 then
    begin
      LastEntryFound:=True;
      break;
    end;
    with FSEntry^ do
    begin
      if (Attrib2=$0f) and (StartCluster_0=0) then
      begin  // LFN Record

        for a:=0 to 4 do
            UniLongName^[(Counter and 31 -1)*13+a]:=First5[a];
        for a:=0 to 5 do
            UniLongName^[(Counter and 31 -1)*13+5+a]:=Second6[a];
        for a:=0 to 1 do
            UniLongName^[(Counter and 31 -1)*13+11+a]:=Third2[a];
        Checksum_in_LFN:=Checksum;

      end else
      begin  // Normal Record
        if (FileName[0]<>chr($E5)) then // if Not Deleted
        begin
          shname:='';ext:='';
          for a:=0 to 7 do
            if (FileName[a]<>' ') then
              shname:=shname+FileName[a];
          for a:=0 to 2 do
            if (Extension[a]<>' ') then
              ext:=ext+Extension[a];

          if ext<>'' then shname:=shname+'.'+ext;

          fillchar(Longname^,sizeof(Longname^),0);
          if Checksum_in_LFN=Count_Checksum(fsentry^) then // if this LFN entry belongs to this short filename, then
          begin
            Unicode2PChar(UniLongName,LongName);             // Convert unicode long filename to simple string.
            Store_Longname_in_EALIST(path+shname,LongName);  // Store it in EAList, if Longname is not an empty string, and if
                                                             // it has not been stored there yet (from .LONGNAME EA...)
          end;

          new(uj);                                         // Store this FS Entry in directory tree:
          uj^.next:=Nil;
          uj^.sub:=Nil;
          uj^.Entry:=FSEntry^;
          uj^.fname:=shname;
          AppendToList(Head,uj);
        end;// else writeln(' ----- Deleted');
        fillchar(UniLongName^,sizeof(UniLongName^),0);     // Set longname:='', because it was a normal record,
                                                           // so the collection of LFN chunks should restart.
      end;
    end; // of "With FSEntry^ do"

    // Go to next FS entry!
    inc(SubSectorEntry);inc(EntryNum);
    // Do we have to read next sector for the next entry?
    if (SubSectorEntry=EntriesPerSector) then               // 0..15: 16 entries in one sector
    begin  // Read Next sector!
      SubSectorEntry:=0;
      inc(Sector);
      ReadSector(Sector,pointer(Data),4096);
    end;
  end;

  // Look for sub-directories

  uj:=head;
  while uj<>Nil do
  begin

    if uj^.Entry.Attrib1 and 16=16 then
    begin // A Directory! Call ourselves recursively!
      if (uj^.fname<>'.') and (uj^.fname<>'..') then
        Read_Sector((uj^.Entry.StartCluster-2)*BPB.SectorsPerCluster + ClustersStart
                               ,Path+uj^.fname+'\',uj^.Entry.StartCluster,uj^.Sub);
    end;
    uj:=uj^.next;
  end;

  Dispose(Data);
  Dispose(UniLongname);
  Dispose(LongName);
  Dispose(FSEntry);
end;

//////////////////////////////////////////////////////////////////////////
//
// GetLongNameForFile
//
// Checks if an EA is stored in EAList for a given file or directory.
//
Function GetLongNameForFile(pathname:string):pEAList_Type;
var act:pEAList_Type;
begin
  act:=EAList;
  result:=Nil;
  while act<>Nil do
  begin
    if UpStr(act^.pathname)=UpStr(pathname) then result:=act;
    act:=act^.next;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Create_Sector
//
// Builds sectors conatining directory entries from the directory tree.
// Builds a special, root directory if the RootDir parameter is true.
//
procedure Create_Sector(sector:ulong;Path:String;Cluster:Word;var Head:pFSEntryList_Type;RootDir:Boolean);
var b,a:byte;
    lnEntry:pEAList_Type;
    FSEntry:pFSEntryType;
    LongName:pCharArray;
    Data:pDataArray;
    ActualEntry,uj:pFSEntryList_Type;
    LastEntryFound:boolean;
    EntryNum:ULong;           // Number of actual directory entry
    SubSectorEntry:Byte;      // Actual entry in currently readed sector
    SectorNum:Word;
    w:word;

  Procedure WriteNormalEntry(Entry:FSEntryType); // Writes normal FS entries, so non-LFN ones.
  var l:longint;
  begin
    Move(Entry,mem[ulong(Data)+SubSectorEntry*32],32);
    inc(SubSectorEntry);inc(EntryNum);
    if SubSectorEntry>=EntriesPerSector then
    begin // Sector is full, write needed!
      SubSectorEntry:=0;
      WriteSector(Sector,pointer(Data),BPB.BytesPerSector);
      inc(SectorNum);
      if RootDir then
      begin
        inc(Sector);
      end else
      begin // Non-root directory, allocate cluster if necessary
        if SectorNum<=BPB.SectorsPerCluster then inc(Sector) else
        begin
          l:=FirstFreeFATEntry(Cluster);
          if l<0 then
          begin
            writeln('*** Disk full, cannot create directory structure! ***');
            writeln('*** Cluster lost! ***');
          end else
          begin
            SetFATEntry(Cluster,l);
            SetFATEntry(l,$FFFF);//EOF
            Cluster:=l;
            SectorNum:=1;
            Sector:=(Cluster-2)*BPB.SectorsPerCluster + ClustersStart;
          end;
        end;
      end;
      FillChar(Data^,sizeof(Data^),0);
    end;
  end;

  Procedure WriteLFNEntry(lnEntry:pEAList_Type;Entry:FSEntryType);
  var uj,entries:pFSEntryList_Type; // Writes LFN FS-entries, using unicode
      sum,i:Byte;
      w,a,b:word;
      Count:byte;
      EOS:boolean;
      UniLongName:pUniCharArray;
      s:string;

  begin
    sum:=Count_Checksum(Entry);
    Entries:=Nil;
    w:=1;Count:=1;EOS:=False;

    GetMem(UniLongName,(length(lnEntry^.LongName)+1)*2); // Create unicode longname from normal string
    FillChar(UniLongName^,(length(lnEntry^.LongName)+1)*2,0); // Fill with zeros first!
    s:=lnEntry^.LongName+chr(0);
    pChar2UniCode(@s[1],UniLongName);                    // Create!

    // Now create LFN entries from the Unicode string!
    while w<=UniStringLength(UniLongName,length(lnEntry^.LongName)+1)+1 do
    begin
      new(uj);
      with uj^.Entry do
      // Fill the LFN entries with the unicode characters, converted from the long filename.
      begin {First5, second6, third2}
        for a:=0 to 4 do
        begin
          if EOS then First5[a]:=$FFFF else
                      First5[a]:=memw[longint(UniLongName)+(w-1)*2]; // W'th Unicode character
          if w>UniStringLength(UniLongName,System.length(lnEntry^.LongName)+1) then EOS:=True; // One zero has been written, now we need $FF's!
          inc(w);
        end;
        for a:=0 to 5 do
        begin
          if EOS then Second6[a]:=$FFFF else
                      Second6[a]:=memw[longint(UniLongName)+(w-1)*2]; // W'th Unicode character
          if w>UniStringLength(UniLongName,System.length(lnEntry^.LongName)+1) then EOS:=True; // One zero has been written, now we need $FF's!
          inc(w);
        end;
        for a:=0 to 1 do
        begin
          if EOS then Third2[a]:=$FFFF else
                      Third2[a]:=memw[longint(UniLongName)+(w-1)*2]; // W'th Unicode character
          if w>UniStringLength(UniLongName,System.length(lnEntry^.LongName)+1) then EOS:=True; // One zero has been written, now we need $FF's!
          inc(w);
        end;
        Counter:=Count; inc(Count);
        Attrib2:=$0f;  // R/O+System+Hidden+VolumeLabel = LFN entry
        Reserved2:=0;
        Checksum:=sum;
        StartCluster_0:=0;
      end;
      uj^.next:=Entries;
      Entries:=uj;
    end;

    FreeMem(UniLongName);

    Entries^.Entry.Counter:=Entries^.Entry.Counter or $40; // Last LFN record
    while Entries<>Nil do
    begin
      WriteNormalEntry(Entries^.Entry);
      uj:=Entries;
      Entries:=Entries^.Next;
      Dispose(uj);
    end;
    WriteNormalEntry(Entry);
  end;

  Procedure Flush_Write; // Writes the last sector to disk, and sets it in FAT too.
  begin
    if SubSectorEntry>0 then WriteSector(Sector,pointer(Data),BPB.BytesPerSector);
    if not RootDir then SetFATEntry(Cluster,$FFFF);  //EOF
  end;

begin
  new(FSEntry);
  new(LongName);
  new(Data);
  EntryNum:=0;
  SubSectorEntry:=0;
  SectorNum:=1;
  FillChar(Data^,sizeof(Data^),0);
  ActualEntry:=Head;
  if RootDir then
  begin          // Creating Root directory
    while (ActualEntry<>Nil) and (EntryNum<BPB.RootEntries) do
    begin
     lnEntry:=GetLongNameForFile(path+ActualEntry^.fname);
     if lnEntry<>Nil then WriteLFNEntry(lnEntry,ActualEntry^.Entry)
                     else WriteNormalEntry(ActualEntry^.Entry);
     ActualEntry:=ActualEntry^.Next;
     if Dots then write('.');
    end;
  end else
  begin          // Creating sub-directory
    SetFATEntry(Cluster,$FFFF); //EOF
    while (ActualEntry<>Nil) do
    begin
     lnEntry:=GetLongNameForFile(path+ActualEntry^.fname);
     if lnEntry<>Nil then WriteLFNEntry(lnEntry,ActualEntry^.Entry)
                     else WriteNormalEntry(ActualEntry^.Entry);
     ActualEntry:=ActualEntry^.Next;
     if Dots then write('.');
    end;
  end;
  Flush_Write;
  if (RootDir) and (ActualEntry<>Nil) then
  begin
    Writeln('*** WARNING! Too small root directory size! ***');
    writeln('*** Some directory entries has been lost! ***');
  end;
  uj:=head;
  while uj<>Nil do
  begin
    if uj^.Entry.Attrib1 and 16=16 then
    begin // A Directory!
      if (uj^.fname<>'.') and (uj^.fname<>'..') then
        Create_Sector((uj^.Entry.StartCluster-2)*BPB.SectorsPerCluster + ClustersStart
                      ,Path+uj^.fname+'\',uj^.Entry.StartCluster,Uj^.sub,False);
    end;
    uj:=uj^.next;
  end;
  if RootDir and Dots then Writeln;
  Dispose(Data);
  Dispose(LongName);
  Dispose(FSEntry);
end;

//////////////////////////////////////////////////////////////////////////
//
// Free_FAT_Chain
//
// Frees a chain in FAT starting from Cluster
//
Procedure Free_FAT_Chain(cluster:longint);
var Next:Longint;
begin
  repeat
    Next:=NextClusterFromFAT(Cluster);
    SetFATEntry(Cluster,0); // 0 = Free, <0 = EOF
    Cluster:=Next;
  until Cluster<=0;
end;

//////////////////////////////////////////////////////////////////////////
//
// Erase_Sector
//
// Erases files by freeing ther FAT chains. Erases all files and
// directories in Directory tree.
//
procedure Erase_Sector(var Head:pFSEntryList_Type;Cluster:Longint);
var seged:pFSEntryList_Type;
begin
  Free_FAT_Chain(Cluster); // Free this directory in FAT
  seged:=Head;
  while seged<>Nil do
  begin
    if seged^.sub<>Nil then Erase_Sector(seged^.sub,seged^.Entry.StartCluster);
    seged:=seged^.next;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Erase_RootSector
//
// Erases all files and directories in Directory tree. Starts with
// root directory, where the FAT doesn't have to be modified.
//
procedure Erase_RootSector(var Head:pFSEntryList_Type);
var seged:pFSEntryList_Type;
begin  // The sectors of root directory are not in FAT, in theory. :)
  seged:=Head;
  while seged<>Nil do
  begin
    if seged^.sub<>Nil then Erase_Sector(seged^.sub,seged^.Entry.StartCluster);
    seged:=seged^.next;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// ProcessSector
//
// Looks for LFN entries in given sector, and stores them in main list
// with their short names. Calls itself recursively for directories.
//
procedure ProcessSector(sector:ulong;Path:String;Cluster:LongInt);
var b,a:byte;
    FSEntry:pFSEntryType;
    shname:String[12];
    ext:string[3];
    LongName:pCharArray;
    UniLongName:pUniCharArray;
    Checksum_in_LFN:byte;
    Data:pDataArray;
    Head,uj:pListType;
    LastEntryFound:boolean;
    SubSectorEntry:Byte;      // Actual entry in currently readed sector
    SectorNum:Word;           // Actual Sector number in current cluster
    NextCluster:LongInt;
begin
  new(FSEntry);
  new(LongName);
  new(UniLongName);
  new(Data);
  LastEntryFound:=False;
  Head:=Nil;
  SubSectorEntry:=0;
  ReadSector(Sector,pointer(Data),4096);
  SectorNum:=1;
  NextCluster:=NextClusterFromFAT(Cluster);

  FillChar(UniLongName^,Sizeof(UniLongName^),0);
  while (not LastEntryFound) do
  begin
    move(Data^[SubSectorEntry*32],FSEntry^,32);
    if FSEntry^.Counter=0 then
    begin
      LastEntryFound:=True;
      break;
    end;
    with FSEntry^ do
    begin
      if (Attrib2=$0f) and (StartCluster_0=0) then
      begin  // LFN Record

//        Write('LFN #',Counter and 31,' ');
//        for a:=0 to 31 do if Data^[b*32+a]<15 then write('.') else write(chr(Data^[b*32+a]));
//        writeln;

        for a:=0 to 4 do
            UniLongName^[(Counter and 31 -1)*13+a]:=First5[a];
        for a:=0 to 5 do
            UniLongName^[(Counter and 31 -1)*13+5+a]:=Second6[a];
        for a:=0 to 1 do
            UniLongName^[(Counter and 31 -1)*13+11+a]:=Third2[a];
        checksum_in_lfn:=checksum;
//        for a:=0 to 40 do if LongName^[a]=chr(0) then write('_') else write(LongName^[a]);
//        writeln;
      end else
      begin  // Normal Record
        if (FileName[0]<>chr($E5)) then // if Not Deleted
        begin
          shname:='';ext:='';
          for a:=0 to 7 do
            if (FileName[a]<>' ') then
              shname:=shname+FileName[a];
          for a:=0 to 2 do
            if (Extension[a]<>' ') then
              ext:=ext+Extension[a];

          if ext<>'' then shname:=shname+'.'+ext;

          fillchar(Longname^,sizeof(Longname^),0);
          if Checksum_in_LFN=Count_Checksum(fsentry^) then // if this LFN entry belongs to this short filename, then
          Unicode2PChar(UniLongName,LongName);             // Convert unicode long filename to simple string.

          if (ToDoPath='') or (HeadOf(path+shname,ToDoPath)) then
          begin
            if QueryOnly then
            begin
              write(path+shname);
              if strcomp(pchar(LongName),'')<>0 then writeln(' -> [ ',StrPas(pchar(LongName)),' ]') else
                                                     writeln;
            end else
            if Dots then write('.');
          end;
          new(uj);
          uj^.next:=Head;
          uj^.path:=path;
          uj^.shname:=shname;
          uj^.longname:=StrPas(pchar(LongName));
          uj^.StartCluster:=StartCluster;
          uj^.Attrib:=Attrib1;
          Head:=Uj;
        end;// else writeln(' ----- Deleted');
        fillchar(UniLongName^,sizeof(UniLongName^),0);  // longname:='';
      end;
    end; // of With FSEntry^ do
    inc(SubSectorEntry);
    if (SubSectorEntry=EntriesPerSector) then               // 0..15: 16 entries in one sector
    begin  // Read Next sector
      SubSectorEntry:=0;
      inc(SectorNum);
      if SectorNum<=BPB.SectorsPerCluster then inc(Sector) else
      begin
        if NextCluster<0 then
        begin   // It was the last cluster!
          LastEntryFound:=True;
        end else
        begin
          SectorNum:=1;
          Cluster:=NextCluster;
          if Cluster<-8 then LastEntryFound:=True else
          begin
            NextCluster:=NextClusterFromFAT(Cluster);
            Sector:=(Cluster-2)*BPB.SectorsPerCluster + ClustersStart;
          end;
        end;
      end;
      if not LastEntryFound then
        ReadSector(Sector,pointer(Data),4096);
    end;
  end;

  // Look for sub-directories

  uj:=head;
  while uj<>Nil do
  begin

    if uj^.Attrib and 16=16 then
    begin // A Directory!
      if (uj^.shname<>'.') and (uj^.shname<>'..') then
        ProcessSector((uj^.StartCluster-2)*BPB.SectorsPerCluster + ClustersStart
                     ,Path+uj^.shname+'\',uj^.StartCluster);
    end;
    uj:=uj^.next;
  end;

  if head<>Nil then
  begin  // Link this list in front of the main list of files.
    uj:=head;
    while uj^.next<>nil do uj:=uj^.next;
    uj^.next:=MainHead;
    MainHead:=Head;
  end;

  Dispose(Data);
  Dispose(UniLongName);
  Dispose(LongName);
  Dispose(FSEntry);
end;

//////////////////////////////////////////////////////////////////////////
//
// Process_RootSector
//
// Same as ProcessSector, just for root directory, which needs special
// things.
//
procedure Process_RootSector(sector:ulong;Path:String;NumOfDirEntries:Word);
var b,a:byte;
    FSEntry:pFSEntryType;
    shname:String[12];
    ext:string[3];
    LongName:pCharArray;
    UniLongName:pUniCharArray;
    Checksum_in_LFN:byte;
    Data:pDataArray;
    Head,uj:pListType;
    LastEntryFound:boolean;
    EntryNum:ULong;           // Number of actual directory entry
    SubSectorEntry:Byte;      // Actual entry in currently readed sector
begin
  new(FSEntry);
  new(LongName);
  new(UniLongName);
  new(Data);
  LastEntryFound:=False;
  Head:=Nil;
  EntryNum:=0;
  SubSectorEntry:=0;
  ReadSector(Sector,pointer(Data),4096);

  FillChar(UniLongName^,Sizeof(UniLongName^),0);
  while (not LastEntryFound) and (EntryNum<NumOfDirEntries) do
  begin
    move(Data^[SubSectorEntry*32],FSEntry^,32);
    if FSEntry^.Counter=0 then
    begin
      LastEntryFound:=True;
      break;
    end;
    with FSEntry^ do
    begin
      if (Attrib2=$0f) and (StartCluster_0=0) then
      begin  // LFN Record

//        Write('LFN #',Counter and 31,' ');b:=EntryNum;
//        for a:=0 to 31 do if Data^[b*32+a]<15 then write('.') else write(chr(Data^[b*32+a]));
//        writeln;

        for a:=0 to 4 do
            UniLongName^[(Counter and 31 -1)*13+a]:=First5[a];
        for a:=0 to 5 do
            UniLongName^[(Counter and 31 -1)*13+5+a]:=Second6[a];
        for a:=0 to 1 do
            UniLongName^[(Counter and 31 -1)*13+11+a]:=Third2[a];
        Checksum_in_LFN:=Checksum;

//        for a:=0 to 40 do if LongName^[a]=chr(0) then write('_') else write(LongName^[a]);
//        writeln;
      end else
      begin  // Normal Record
        if (FileName[0]<>chr($E5)) then // if Not Deleted
        begin
          shname:='';ext:='';
          for a:=0 to 7 do
            if (FileName[a]<>' ') then
              shname:=shname+FileName[a];
          for a:=0 to 2 do
            if (Extension[a]<>' ') then
              ext:=ext+Extension[a];

          if ext<>'' then shname:=shname+'.'+ext;

          fillchar(Longname^,sizeof(Longname^),0);
          if Checksum_in_LFN=Count_Checksum(fsentry^) then // if this LFN entry belongs to this short filename, then
          Unicode2PChar(UniLongName,LongName);             // Convert unicode long filename to simple string.

          if (ToDoPath='') or (HeadOf(path+shname,ToDoPath)) then
          begin
            if QueryOnly then
            begin
              write(path+shname);
              if strcomp(pchar(LongName),'')<>0 then writeln(' -> [ ',StrPas(pchar(LongName)),' ]') else
                                                     writeln;
            end else
            if Dots then write('.');
          end;
          new(uj);
          uj^.next:=Head;
          uj^.path:=path;
          uj^.shname:=shname;
          uj^.longname:=StrPas(pchar(LongName));
          uj^.StartCluster:=StartCluster;
          uj^.Attrib:=Attrib1;
          Head:=Uj;
        end;// else writeln(' ----- Deleted');
        fillchar(UniLongName^,sizeof(UniLongName^),0);  // longname:='';
      end;
    end; // of With FSEntry^ do
    inc(SubSectorEntry);inc(EntryNum);
    if (SubSectorEntry=EntriesPerSector) then               // 0..15: 16 entries in one sector
    begin  // Read Next sector
      SubSectorEntry:=0;
      inc(Sector);
      ReadSector(Sector,pointer(Data),4096);
    end;
  end;

  // Look for sub-directories

  uj:=head;
  while uj<>Nil do
  begin

    if uj^.Attrib and 16=16 then
    begin // A Directory!
      if (uj^.shname<>'.') and (uj^.shname<>'..') then
        ProcessSector((uj^.StartCluster-2)*BPB.SectorsPerCluster + ClustersStart
                     ,Path+uj^.shname+'\',uj^.StartCluster);
    end;
    uj:=uj^.next;
  end;

  if head<>Nil then
  begin  // Link this list in front of the main list of files.
    uj:=head;
    while uj^.next<>nil do uj:=uj^.next;
    uj^.next:=MainHead;
    MainHead:=Head;
  end;

  Dispose(Data);
  Dispose(UniLongname);
  Dispose(LongName);
  Dispose(FSEntry);
end;


//////////////////////////////////////////////////////////////////////////
//
// Lock_Drive
//
// Tries to lock the opened drive (using file handle HF)
//
function Lock_Drive:ApiRet;
var Params:byte;
    parmlenmax,datalenmax:ulong;
    data:word;
begin
  params:=0;parmlenmax:=1;
  datalenmax:=1;
  Lock_Drive:=DosDevIOCTL(hf,IOCTL_DISK,DSK_LockDrive,@params,parmlenmax,@parmlenmax,@data,datalenmax,@datalenmax);
end;

//////////////////////////////////////////////////////////////////////////
//
// UnLock_Drive
//
// Tries to unlock the opened drive (using file handle HF)
//
function UnLock_Drive:ApiRet;
var Params:byte;
    parmlenmax,datalenmax:ulong;
    data:word;
begin
  params:=0;parmlenmax:=1;
  datalenmax:=1;
  UnLock_Drive:=DosDevIOCTL(hf,IOCTL_DISK,DSK_UnLockDrive,@params,parmlenmax,@parmlenmax,@data,datalenmax,@datalenmax);
end;

//////////////////////////////////////////////////////////////////////////
//
// AddLongnameEA
//
// Adds/Replaces .LONGNAME EA for a file described by TH
//
procedure AddLongnameEA(var th:pListType);
var rc:boolean;
begin
  if (th^.longname<>'') and (th^.shname<>'.') and (th^.shname<>'..') and (th^.attrib and 8 = 0) then // not Volume Label!
  begin
    rc:=Set_ASCII_EA(drive+th^.path+th^.shname, '.LONGNAME', th^.LongName);
    if (rc=false) and (ShowEAErrors) then
    begin
      writeln('Warning: Could not set EA for ',drive+th^.path+th^.shname);
    end;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Read_BPB
//
// Reads the Bios Parameter Block into BPB variable
//
Function Read_BPB:ApiRet;
Type DataType=record
       EBPB:BPB_Type;
       NumOfCylinders:SmallWord;
       DevType:Byte;
       DevAttr:SmallWord;
     end;
var Packet:array[0..1] of byte;
    PacketSize:longint;
    Data:DataType;
    DataSize:Longint;
    rc:ApiRet;
begin
  Packet[0]:=GetDeviceParams_CommandInfoByte;
  Packet[1]:=0;
  PacketSize:=2;
  DataSize:=sizeof(DataType);
  rc:=DosDevIOCTL(hf,IOCTL_DISK,DSK_GETDEVICEPARAMS,@Packet,PacketSize,@PacketSize,
                                                  @Data,DataSize,@DataSize);
  if rc<>no_Error then
  begin
    Writeln('Error querying device parameters (@Read_BPB): rc=',rc);
  end else
  begin
    Move(Data.EBPB,BPB,sizeof(Data.EBPB));
  end;
  Read_BPB:=rc;
end;

//////////////////////////////////////////////////////////////////////////
//
// Read_BootSector
//
// Reads the bootsector into global DATA variable
//
procedure Read_BootSector;
begin
  if FloppyMode then
  begin // work with floppys
    ReadDirect(0,0,1,Data,4096); //Cyl,Head,Sect
  end else
  begin // word with HDDs
    ReadDirect(0,1,1,Data,4096); //Cyl,Head,Sect
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Read_FAT
//
// Reads the FAT into the global FAT variable. Also allocates memory!
//
Procedure Read_FAT;
var w:ulong;
    adr:pointer;
begin
  FATSize:=BPB.BytesPerSector*BPB.SectorsPerFAT;
  GetMEM(FAT,FATSize);
  for w:=1 to BPB.SectorsPerFAT do
  begin
    adr:=ptr(ofs(FAT^)+(w-1)*BPB.BytesPerSector);
    ReadSector(BPB.ReservedSectors+w-1,adr,BPB.BytesPerSector);
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Write_FAT
//
// Writes FAT back to drive
//
Procedure Write_FAT;
var w:ulong;
    adr:pointer;
begin
  for w:=1 to BPB.SectorsPerFAT do
  begin
    adr:=ptr(ofs(FAT^)+(w-1)*BPB.BytesPerSector);
    WriteSector(BPB.ReservedSectors+w-1,adr,BPB.BytesPerSector);
  end;
  for w:=1 to BPB.SectorsPerFAT do  // Write 2nd FAT copy
  begin
    adr:=ptr(ofs(FAT^)+(w-1)*BPB.BytesPerSector);
    WriteSector(BPB.ReservedSectors+w-1+BPB.SectorsPerFAT,adr,BPB.BytesPerSector);
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Free_FAT
//
// Releases memory allocated for FAT
//
procedure Free_FAT;
begin
  FreeMem(FAT,FATSize);
  FAT:=Nil;
end;

//////////////////////////////////////////////////////////////////////////
//
// GetStringEA
//
// Converts the ASCII-type EA to a pascal style string.
// The EA is pointed by the L parameter, which is actually a pointer.
//
function GetStringEA(l:ulong):string;
var h,w:word;
    e:string;
begin
  w:=smallword(ptr(l+2)^);
  e:='';
  for h:=1 to w do e:=e+chr(byte(ptr(l+h+3)^));
  result:=e;
end;

//////////////////////////////////////////////////////////////////////////
//
// GetLongnameEA
//
// Reads the .LONGNAME EA for the given file.
// Returns empty string if there is no EA stored for the file.
//
function GetLongnameEA(fname:string):string;
begin

  if (fname<>'') and (fname<>'.') and (fname<>'..') then // not Volume Label!
  begin
    result:=Get_ASCII_EA(fname, '.LONGNAME');
  end else result:='';
end;


//////////////////////////////////////////////////////////////////////////
//
// Collect_EAs
//
// Builds EAList by recursively collecting .LONGNAME EAs for files
//
Procedure Collect_EAs(path:string);
var rec:tsearchrec;
    rc:apiret;
    uj:pEAList_Type;

  Function NoDrive(s:String):string;
  begin
    delete(s,1,2);
    result:=s;
  end;

begin
  rc:=findfirst(path+'*',faAnyFile,rec);
  while rc=0 do
  begin
    if (rec.name<>'.') and (rec.name<>'..') then
    begin
      new(uj);uj^.next:=EAList;uj^.LongName:=GetLongnameEA(path+rec.name);uj^.pathname:=NoDrive(path+rec.name);
      if uj^.longname='' then
      begin
        dispose(uj);
      end else
      begin
        ealist:=uj;
        if Dots then write('.') else
        if QueryOnly then writeln(path+rec.name,' -> ',EAList^.LongName);
      end;
      if (rec.Attr and faDirectory=faDirectory) then
      begin
        Collect_EAs(path+rec.name+'\');
      end;
    end;
    rc:=findnext(rec);
  end;
  findclose(rec);
end;

//////////////////////////////////////////////////////////////////////////
//
// Release_Collected_EAs
//
// Frees the list EALIST
//
procedure Release_Collected_EAs;
var todelete:pEAList_Type;
begin
  while EAList<>Nil do
  begin
    todelete:=ealist;ealist:=ealist^.next;
    dispose(todelete);
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// Free_DirStruct
//
// Frees the Directory tree
//
procedure Free_DirStruct(var head:pFSEntryList_Type);
var todelete:pFSEntryList_Type;
begin
  while head<>Nil do
  begin
    if head^.sub<>Nil then Free_DirStruct(head^.sub);
    todelete:=head;
    head:=head^.next;
    dispose(todelete);
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// File_System_Name
//
// Queries the file system name from OS/2 for the drive DRIVE_NUMBER
//
Function File_System_Name(drive_number:byte):string;
Type tDataPacket=record
       BPB:array[0..30] of byte;
       Cylinders:UShort;
       DevType:Byte;
       DevAttr:UShort;
     end;
var ParmList:array[0..1] of byte;
    DataSize:Ulong;
    PSize:ULong;
    DataArea:tDataPacket;
    rc:ApiRet;
    device_name:Array[0..2] of byte;
    dqfsabuffer:array[0..1023] of byte;
    pBuffer:pFSQBuffer2;
    buffer_size:ULONG;
    _fsallocate:fsallocate;
begin
  pbuffer:=@dqfsabuffer;
  device_name[1]:=byte(':');
  device_name[2]:=0;
  ParmList[0]:=0;
  DataSize:=0;
  PSize:=2;
  rc:=DosQueryFSInfo(drive_number,1,_fsallocate,sizeof(fsallocate));
  if (rc = 0)  then
  begin
    device_name[0]:=byte('A') + drive_number - 1;
    buffer_size:=sizeof(dqfsabuffer);
    rc:=DosQueryFSAttach( @device_name, 0, 1, @dqfsabuffer, buffer_size);
    if rc=0 then
    begin
      if pBuffer^.iType=FSAT_LOCALDRV then
      begin     // We have a local drive here
        result:=StrPas((pbuffer^.szFSDName)+pbuffer^.cbName);
      end else
      begin    // We have a remote drive here
        result:='REMOTE';
      end;
    end;
  end;
  if rc<>0 then
  begin  // Cannot query this drive on the default way
         // maybe Drive not ready or Invalid Drive...
    if rc=15 then                        // 15 = error_Invalid_Drive_Specified
    begin
      result:='Invalid';
    end else
    if (rc=21) or (rc=27) then           // 21 = error_Not_Ready, 27 = sector_not_found
    begin                                // Maybe a CD-ROM with no cd inserted or with an audio CD? Query!
      ParmList[1]:=Drive_Number-1;
      rc := DosDevIOCtl(-1, 8, $63, @ParmList,  PSize, @PSize,
                        @DataArea,  sizeof(tDataPacket), @DataSize);
      if (rc=0) and
         ((DataArea.DevType=7) and (DataArea.DevAttr=6)) then
      begin  // Yes, it's a CD-ROM
        result:='CDFS';
      end;   // else error with DosDevIOCtl... same as below.
    end else
    begin  // else we cannot determine the filesystem type,
           // maybe because of Access_Denied or something else...
      result:='Unknown';
    end;
  end;
end;

//////////////////////////////////////////////////////////////////////////
//
// VFAT2EA_New_ExitProc
//
// New exitproc, that takes care of cleanup and everything, even in case
// of crash.
//
procedure VFAT2EA_New_Exitproc;
begin
  exitproc:=VFAT2EA_Old_Exitproc;
  Release_Collected_EAs;
  Free_DirStruct(DirStruct);
  if MemUsed<>FirstMemUsed then
  begin
    Writeln('Warning! Memory leaked!');
    writeln(MemUsed-FirstMemUsed,' bytes still allocated!');
  end;
end;

///////////////////////////////// MAIN PROGRAM ///////////////////////////////////////////////////////////////

begin
  FirstMemUsed:=MemUsed;
  VFAT2EA_Old_Exitproc:=exitproc;
  exitproc:=@VFAT2EA_New_Exitproc;

  writeln('VFAT2EA ',version_string,' - written by Doodle and OAX');
  if paramcount<1 then
  begin
    writeln('This program converts VFAT Long Filenames to OS/2''s .LONGNAME EA (VFAT2EA), or');
    writeln('converts back OS/2''s .LONGNAME EAs to VFAT Long Filenames (EA2VFAT).');
    writeln('Usage: VFAT2EA <drive:>[\path] [/QUERY] [/DOTS] [/NOLOCK]');
    writeln('               [/FORCEFAT] [/NOEABUGFIX] [/DRIVEPARAMS] [/B]');
    writeln('  /QUERY        : Don''t convert, only report long filenames to screen.');
    writeln('  /DOTS         : Use dots as progress indicator');
    writeln('  /NOLOCK       : Don''t lock the drive for usage. Not recommended!');
    writeln('  /FORCEFAT     : Use the partition as a FAT one, even if it has been');
    writeln('                  detected to be something else. Not recommended!');
    writeln('  /NOEABUGFIX   : OS/2 has problems with \CHKDSK.LOG and \CHKDSK.OLD');
    writeln('                  files. This program automatically skips them. Use');
    writeln('                  this switch only if you *know*, that this work-');
    writeln('                  around is not necessary for you!');
    writeln('  /DRIVEPARAMS  : Show the recognised parameters of drive');
    writeln('  /SHOWEAERRORS : Show filename if EA could not be set');
    writeln('  /B            : Convert Back EAs to long filenames (EA2VFAT)');
    writeln;
    writeln('Examples:');
    writeln(' VFAT2EA E: /QUERY');
    writeln(' VFAT2EA A:\NEWFIL~1 /DOTS');
    writeln(' VFAT2EA A: /B');
    halt;
  end;
  QueryOnly:=False;NoLock:=False;
  Dots:=False;
  MainHead:=Nil;
  EAList:=Nil;
  DirStruct:=Nil;
  ShowDriveParams:=False;
  ShowEAErrors:=False;
  ForceFAT:=False;
  EA2VFAT:=False;

  GetDeviceParams_CommandInfoByte:=1; // Not changeable anymore

  for t:=2 to paramcount do
  begin
    Param:=UpStr(paramstr(t));

    if Param='/SHOWEAERRORS' then
    begin
      writeln('* Show EA Errors');
      ShowEAErrors:=True;
    end else
    if Param='/DRIVEPARAMS' then
    begin
      writeln('* Show Drive Parameters');
      ShowDriveParams:=True;
    end else
    if Param='/FORCEFAT' then
    begin
      writeln('* Force FAT file system');
      ForceFAT:=True;
    end else
    if Param='/QUERY' then
    begin
      writeln('* Query Only');
      QueryOnly:=true;
    end else
    if Param='/DOTS' then
    begin
      writeln('* Use progress indicator');
      Dots:=True;
    end else
    if Param='/NOLOCK' then
    begin
      writeln('* No drive locking');
      NoLock:=True;
    end else
    if Param='/NOEABUGFIX' then
    begin
      writeln('* Don''t ignore \CHKDSK.LOG and \CHKDSK.OLD files');
      EA.IgnoreCHKDSK:=False;
    end else
    if Param='/B' then
    begin
      writeln('* Convert back EAs to VFAT Long Filenames (EA2VFAT)');
      writeln('  -------------------------------------------------');
      EA2VFAT:=True;
    end else
    writeln('! Invalid parameter: [ ',paramstr(t),' ]');
  end;

  drive:=paramstr(1);
  if EA2VFAT then                 // For EA2VFAT, only a drive can be accepted
  begin
    if (length(Drive)<>2) or (Drive[2]<>':') then
    begin
      writeln('Invalid drive specification: ',drive);
      halt(-1);
    end;
    Writeln('Collecting .LONGNAME EAs...');
    Collect_EAs(Drive+'\');
    if Dots then writeln;
    if QueryOnly then
    begin
      halt;
    end;
  end else
  begin                           // For VFAT2EA, a path can be there too...
    if (length(Drive)<2) or (Drive[2]<>':') then
    begin
      writeln('Invalid drive specification: ',drive);
      halt(-1);
    end;
    ToDoPath:=paramstr(1);
    delete(ToDoPath,1,2);
    if ToDoPath<>'' then
    begin
      writeln('* Accessing only directory [',ToDoPath,']');
    end;
  end;

  // Open the drive
  // For this, first we have to create a C-style string
  Drive[0]:=chr(2);
  getmem(devname,128);
  move(drive[1],devname^,length(drive));
  mem[ulong(devname)+length(drive)]:=0;         // string->pchar
  // Now open
  rc:=DosOpen(devname,hf,action,0,0,open_action_Open_If_Exists,
               Open_Flags_DASD or Open_share_DenyNone or Open_access_ReadOnly ,nil);
  // No need for the C-style string anymore
  freemem(devname,128);

  if rc<>0 then
  begin
    Writeln('Error opening [ ',drive,' ] !');
    writeln('DosOpen Error: rc=',rc);
    halt(rc);
  end;

  if not NoLock then
  begin
    rc:=Lock_Drive;
    if rc<>0 then
    begin
      writeln('Failed to lock drive! rc=',rc);
      DosClose(hf);
      halt(rc);
    end;
  end;

  if Read_BPB<>No_Error then  // reads BPB from OS/2
  begin
    writeln('Failed to read BPB! rc=',rc);
    DosClose(hf);
    halt(rc);
  end;

  if BPB.MediaDescriptor=248 then FloppyMode:=False else
                                  FloppyMode:=True;
  if FloppyMode then
  begin
    Writeln('* Working with a floppy disk');
  end else
  begin
    Writeln('* Working with a hard disk');
  end;
  Read_BootSector;
  // We can also use the BPB from disk, or the BPB reported by OS/2.
  // I think it's better to use the one from OS/2, but if it's needed,
  // the following line can be uncommented to use the BPB stored on the disk.
//  move(Data[11],BPB,sizeof(BPB));

  // Copy the partition type string out from BPB into sign variable
  sign:='';
  for t:=0 to 7 do  if data[54+t]<>0 then sign:=sign+chr(data[54+t]) else sign:=sign+' ';
  if ForceFAT then FatType:=tFATDetect else
                   FatType:=tNOFAT;

  // Then query the partition type string from OS/2
  writeln('* Querying partition type from OS/2... ');
  os2reported_sign:=File_System_Name(byte(upcase(Drive[1]))-64);
  if os2reported_sign='FAT' then
  begin
    // Ok, OS/2 thinks it's a FAT partition, now let's dig deeper,
    // let's see what's in the BPB!
    //       12345678
    if sign='FAT16   ' then FATType:=tFAT16;
    if sign='FAT12   ' then FATType:=tFAT12;
    if sign='FAT     ' then FATType:=tFATDetect;

    if FATType=tNoFAT then
    begin
      // Interesting, OS/2 said it's a FAT partition, but it does not
      // seem to be, according to the BPB!
      // So, set the partition-type to FATByOS2!
      // Could not detect the file system for the drive!
      FATType:=tFATDetect;
      sign:='FATbyOS2';
    end;
    writeln('* Found a FAT partition: [',sign,']');
  end else
  begin
    writeln('* Found a non-FAT partition.');
    writeln('  OS/2 reported: [',os2reported_sign,']');
    writeln('  Read from BPB: [',sign,']');
  end;

  if FATType<>tNoFAT then
  begin
    if ShowDriveParams then
    With BPB do
    begin
      Writeln('  Bytes/Sector: ',BytesPerSector);
      Writeln('  Sectors/Cluster: ',SectorsPerCluster);
      Writeln('  Reserved Sectors: ',ReservedSectors);
      Writeln('  Number of FATs: ',NumberOfFats);
      Writeln('  Root Entries: ',RootEntries);
      Writeln('  Number of sectors: ',NumberOfSectors,' (0 -> use Number of sectors Huge)');
      Writeln('  Media Descriptor: ',MediaDescriptor);
      Writeln('  Sectors/FAT: ',SectorsPerFat);
      Writeln('  Sectors/Head: ',SectorsPerHead);
      Writeln('  Heads/Cylinder: ',HeadsPerCylinder);
      Writeln('  Number of Hidden Sectors: ',NumHiddenSectors);
      Writeln('  Number of sectors Huge: ',NumberOfSectorsHuge);
    end;

    // Calculate some logical sector numbers, and Entries/Sector
    RootStart:=BPB.ReservedSectors+BPB.NumberOfFATs*BPB.SectorsPerFAT ;
    ClustersStart:=RootStart+(BPB.RootEntries*32+BPB.BytesPerSector-1) div BPB.BytesPerSector;
    EntriesPerSector:=BPB.BytesPerSector div 32;

    // Calculate Number of Sectors:
    If BPB.NumberOfSectors=0 then NumberOfSectors:=BPB.NumberOfSectorsHuge else
                                  NumberOfSectors:=BPB.NumberOfSectors;

    if FATType=tFATDetect then
    begin
      NumberOfClusters:=2+(NumberOfSectors-ClustersStart) div BPB.SectorsPerCluster;
      write('* Using it as ');
      if NumberOfClusters<4087 then
      begin
        FATType:=tFAT12;
        writeln('FAT12');
      end;
      if NumberOfClusters>=4087 then
      begin
        FATType:=tFAT16;
        writeln('FAT16');
      end;
    end;
    Writeln('Reading FAT...');
    Read_FAT;
    if not EA2VFAT then
    begin                                            // VFAT2EA
      // Start processing from Root Directory!
      Writeln('Scanning directory structure...');
      Process_RootSector(RootStart,'\',BPB.RootEntries); // Read LFNs, and create EAs from them!
    end else
    begin                                            // EA2VFAT
      // Start processing from Root Directory!
      Writeln('Reading directory structure...');
      Read_RootSector(RootStart,'\',BPB.RootEntries,DirStruct); // Read directory structure
      Writeln('Rebuilding directory structure...');
      Erase_RootSector(DirStruct);                              // Erase stuffs from FAT
      Create_Sector(RootStart,'\',0,DirStruct,True);            // Create new directory structure, containing LFNs
      Writeln('Writing new FAT...');
      Write_FAT;
    end;
    Free_FAT;
  end // of 'Found a FAT partition!'
  else
  begin
    Writeln('Partition type not supported!');
  end;

  if not NoLock then
  begin
    rc:=Unlock_Drive;
    if rc<>0 then
    begin
      writeln('Failed to unlock drive! rc=',rc);
    end;
  end;
  rc:=DosClose(hf);
  if rc<>0 then
  begin
    writeln('DosClose error: rc=',rc);
  end;

  if not EA2VFAT then        // Postprocessing for VFAT2EA: create the .LONGNAME EAs...
  begin
    if FATType<>tNoFAT then
    begin
      if not QueryOnly then
      begin
        writeln;
        Writeln('Creating EAs, please wait...');
      end;

      while MainHead<>Nil do
      begin
        if not QueryOnly then
        begin
          if (ToDoPath='') or (HeadOf(MainHead.path+MainHead.shname,ToDoPath)) then
          begin
            AddLongnameEA(MainHead);
            if Dots then write('.');
          end;
        end;

        Dele:=MainHead;
        MainHead:=MainHead^.next;
        dispose(Dele);
      end;
    end;
  end;
  if not QueryOnly then
  begin
    writeln;
    Writeln('Done!');
  end;
end.
