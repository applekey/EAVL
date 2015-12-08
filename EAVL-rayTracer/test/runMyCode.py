import os
import math

i = 0
x = 69.782
y = 0.0 
z = 69.782

with open("cameraPos.txt") as f:
	for line in f:
		name = "images/NekData/X/vol" + str(i)
		#print name 
		i = i + 1
		x = x + 0.5
		z = z + 0.5 
		myPos = str(x) + " 0 0"
		runInst = "./testvolume -f ~/Data/nek5000Tet.vtk -tf enzo128Tet_camera -res 1024 1024 -fld 0  -o "+ name + " -rot "+ line
		print runInst
		os.system(runInst)
#degree = 15
#for i in range(13):
#	name = "images/vol" + str(i)
	#x = x + math.sin(math.pi/99.0)
	#z = z + 0.5#x + math.cos(math.pi/99.0)
	#y = 0.0
	#rad = degree*math.pi/180.0
#	myRad = str(rad) #+" "+ str(y)+" " + str(z)
#	runInst = "./testvolume -f ~/Data/hardyTet.vtk -tf enzo128Tet_camera  -fld 3  -o "+ name + " -rot "+ myRad
#	print runInst
#	os.system(runInst)
#	degree = degree + 15
