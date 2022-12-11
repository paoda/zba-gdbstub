# ZBA-GDBSTUB

This is a gdbstub server for paoda/zba, because I don't want to import a C library and i _love_ reinventing the wheel I guess.

## Scope

This is tailor made for targeting the GBA. Anything that isn't necessary for stepping through ARMv4T code isn't included. This means lots of hardcoded values and assumptions that would be really awful for any halfway decent gdbstub implementation.

This project will have succeeded as soon as I use it to determine why Rhythm Heaven is stuck in an infinite loop.
