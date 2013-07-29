
  VFAT2EA version v1.5
  --------------------


Introduction:
- - - - - - -
  For FAT partitions, WinXX can assign long filenames to files, and saves them
  in the directory structure. This partition type is called VFAT. OS/2 is not
  able to use these long filenames (except by using VFAT IFS), just the short
  aliases.

  By using VFAT2EA, you'll be able to see, and even copy these long filenames
  *in the WPS*! (Or in any program which manages .LONGNAME EAs, like the in-
  cluded rxcopy one.)

  VFAT2EA converts VFAT Long Filenames to OS/2's .LONGNAME Extended Attributes,
  which is the standard way in OS/2 to store the long filenames for every file
  or directory on a partition, which does not support long filenames.

  For using OS/2 written long filenames in WinXX, use the /B switch. It will
  convert back all .LONGNAME Extended Attributes to VFAT Long Filenames. Before
  using it, please read all this readme file!

Usage:
- - - -
  You'll get help, by starting the programs without parameters.

  For first run, it's recommended to use the /QUERY switch, to see if the prog-
  ram works well for you too. If it's OK, you can run it without that, to do
  the real work.

  The program has two different working modes: VFAT2EA and EA2VFAT. The default
  mode is the VFAT2EA, which means that you can make WinXX written disks usable
  for OS/2. If you specify the /B switch, you switch to EA2VFAT mode, where the
  program will make OS/2 written disks usable for WinXXs. (Well, here usable
  means that you are able to see long filenames...)

  Note, that in EA2VFAT mode, you cannot specify drive+path, only drive.

Warning!
- - - - -
  VFAT2EA is quite a useful and harmless program. Opens the partition or drive,
  reads the directory structure, gets all the Long Filenames from that, and
  appends them to files.
  Even if it does someting wrong, the only problem it can cause is to append
  wrong long filenames.
  But!
  In EA2VFAT mode, it reads and writes your partition. It deletes all informa-
  tion about the files and directories on your partition/disk, and re-creates 
  the structures. This way if it does something wrong (e.g. creates bad direc-
  tory structure or writes something bad into the FAT table) you may loose or 
  damage your files!
  Actually, it does not have a big probability, but be careful!

Sources:
- - - - -
  To compile the sources, all you need is the Virtual Pascal compiler,
  downloadable from www.vpascal.com.
  The whole VFAT2EA stuff is freeware, so use it as you wish, but only
  at your own risk!

History:
- - - - -
 v1.01 : Initial release. Supports only [FAT16   ] partitions.
 v1.06 : A lot of bugfixes.
         Added support for [FAT12   ] and [FAT     ] partitions.
         Added support for floppy disks. (Tried only 3.5/1.44Mb and ZIP drives)
         Can be started to work with subdirectories only.
 v1.07 : New switch: /FORCEFAT
         From now, EA2VFAT is also included as a separate EXE.
 v1.1  : The two programs has been put together, into one EXE.
         New switch: /B (to choose between VFAT2EA and EA2VFAT)
         Added support for Unicode. National characters should be OK now.
         EA2VFAT does not destroy VFAT Long Filenames, which are not known to
          OS/2. (In other words, you don't have to start VFAT2EA before EA2VFAT
          VFAT Long Filenames will be automatically preserved.)
         Improved FAT detector algorithm.
 v1.11 : rxcopy.zip included for easy copying .LONGNAME'd files without the WPS.
         If you have problems with rxcopy, please contact Aliaksandr Dzeshchanka
         (llazy@tut.by) as he is the author of rxcopy!
 v1.3  : Some small bugfixes.
         Changed the way the program converts to unicode to support DBCS.
         (Thanks to Masami Naito for this!)
         Included full source code.
 v1.31 : Fixed upcasing national characters
         Fixed upcasing DBCS strings (by Masami again.:) )
         Fixed a smaller memory leak that might occur sometimes
         (at UpperCase RTL function)
 v1.4  : Replaced OS2EA.PAS with own EA handling unit. This resulted in smaller
          executable file, and should fix a crash.
 v1.5  : Fixed partition type checking mechanism, not to detect HPFS and NTFS 
          to be FAT.

Problems, questions, suggestions, remarks:
- - - - - - - - - - - - - - - - - - - - - -
  They are all welcomed, send them to doodle@scenergy.dfmk.hu .

Others:
- - - -
  This program is freeware.
  Use it at your own risk!
  I'm not responsible for any damage this program may do.
  blah-blah-blah...

END! (like in Cow and Chicken..;) )
