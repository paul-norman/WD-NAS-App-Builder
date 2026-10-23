# Signs the test repository with key A, adds the test recipe, and writes the third-party ("evil") repositories
python3 /tbin/repotool.py sign /www/repo /tcerts/keyA.pem
python3 /tbin/repotool.py add-recipe /www/repo /tfix/hello-1
python3 /tbin/repotool.py evil /www/evil /tfix/hello-1
