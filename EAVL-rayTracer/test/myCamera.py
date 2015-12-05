import math


x = 69.782;
z = 0.0;
y = 0.0;
for i in range(1,180):
	theata = 180.0/i;
	newX = x * math.cos(theata) + z * math.sin(theata);
	newZ = z * math.cos(theata) - x * math.sin(theata);
	print newX, y, newZ
	x = newX;
	z = newZ;