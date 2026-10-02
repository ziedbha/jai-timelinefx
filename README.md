# TimelineFX bindings for Jai

Jai bindings for [TimelineFX](https://github.com/peterigz/timelinefxlib). Windows x64 only for now; support for other platforms can be added as the library becomes cross-platform.

## Setup

You need MSVC C++ build tools because generation will also build the library itself.
From the repository root:

1. Initialize the TimelineFX submodule:

   ```sh
   git submodule update --init --recursive
   ```

2. Build the TimelineFX C++ library and generate the bindings:

   ```sh
   jai generate.jai
   ```

Output goes to `generated/TimelineFX/`.

## Example usage

Add contents of `generated/` to your project's module search path, then import:

```jai
tfx :: #import "TimelineFX";
```
