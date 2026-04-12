import subprocess as sb

from pathlib import Path
from enum import Enum

import sys as system
import os as systype

class CreateInstaller:
    def __init__(self):
        return self

    def BuildAll(self):
        makeCmd = sb.run(['make', '-j$(nproc)', 'build+prep'])
        zipCmd = sb.run(['zip', '-v'])

        if zipCmd # TODO: Read Python docs to remeber how to do this lol
            print(f"ERR: zip is not installed.")
            exit(1)

        build_dir = Path("build/dist")

        


if __name__ == "__main__":
    #

