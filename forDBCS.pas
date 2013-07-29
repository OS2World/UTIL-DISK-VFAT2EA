//
// forDBCS Unit
//
// Simplest sample program for how to use DBCS function.
//

Unit forDBCS;
Interface

{&CDECL+}{&USE32+}

uses OS2Def,OS2Base;

var uchDBCSInfo : array [0..11] of Char;  // DBCS information buffer
function isDBCS1stByte(DBCS1stByte:Char) : Boolean;

implementation

var
  ctrycodeInfo : CountryCode;           // Country code information
  rc: ApiRet;                           // APIRET

// Get the double-byte character set vector from the country file.
function GetDBCSVector : ApiRet;
var
  i : Integer;
begin
  for i := 0 to (sizeof(uchDBCSInfo) - 1) do
  begin
    uchDBCSInfo[i] := #0;               // Clear Buffer
  end;
  ctrycodeInfo.country := 0;            // Current country
  ctrycodeInfo.codepage := 0;           // Current codepage

  Result := DosQueryDBCSEnv(sizeof(uchDBCSInfo), // Size of buffer
                            ctrycodeInfo,        // Country code information
                            uchDBCSInfo);        // DBCS information buffer
end;

// Eval the double-byte character set 1st Byte.
function isDBCS1stByte(DBCS1stByte:Char) : Boolean;
var
  i : Integer;
  rc : ApiRet;
begin
  Result := False;
  for i := 0 to (sizeof(uchDBCSInfo) - 1) do
  begin
    if uchDBCSInfo[i] = #0 then break;
    if(DBCS1stByte >= uchDBCSInfo[i]) and (DBCS1stByte <= uchDBCSInfo[i + 1]) then
    begin
      // find DBCS1stByte
      Result := True;
      break;
    end;
    i := i + 1;
  end;
end;

initialization
  rc := GetDBCSVector;
end. { forDBCS }
