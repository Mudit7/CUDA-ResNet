all:
	nvcc -lcuda -lcublas *.cu -o ResNet  -arch=sm_30 -Wno-deprecated-gpu-targets

run:
	./ResNet
clean:
	rm ResNet
