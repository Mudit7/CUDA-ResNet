#define USE_MNIST_LOADER
#define MNIST_DOUBLE
#include "mnist.h"
#include "layer.h"

#include <cuda.h>
#include <cstdio>
#include <time.h>

static mnist_data *train_set, *test_set;
static unsigned int train_cnt, test_cnt;

// Define layers of CNN
static Layer l_input = Layer(0, 0, 28*28);
static Layer l_c1 = Layer(5*5, 6, 24*24*6);
static Layer l_c2 = Layer(2*2, 6, 12*12*6);
static Layer l_c3 = Layer(2*2, 6, 6*6*6);
static Layer l_f = Layer(6*6*6, 10, 10);

//resnet shortcut
static Layer l_r = Layer(4*4,1,6*6*6);

static void learn();
static unsigned int classify(double data[28][28]);
static void test();
static double forward_pass(double data[28][28]);
static double back_pass();

static inline void loaddata()
{
	mnist_load("data/train-images.idx3-ubyte", "data/train-labels.idx1-ubyte",
		&train_set, &train_cnt);
	mnist_load("data/t10k-images.idx3-ubyte", "data/t10k-labels.idx1-ubyte",
		&test_set, &test_cnt);
}

int main(int argc, const  char **argv)
{
	srand(time(NULL));

	CUresult err = cuInit(0);
	if (err != CUDA_SUCCESS) {
		fprintf(stderr, "CUDA initialisation failed with error code - %d\n", err);
		return 1;
	}

	loaddata();
	learn();
	test();

	return 0;
}

// Forward propagation of a single row in dataset
static double forward_pass(double data[28][28])
{
	float input[28][28];

	for (int i = 0; i < 28; ++i) {
		for (int j = 0; j < 28; ++j) {
			input[i][j] = data[i][j];
		}
	}

	l_input.clear();
	l_c1.clear();
	l_c2.clear();
	l_c3.clear();
	l_f.clear();
	l_r.clear();
	clock_t start, end;
	start = clock();

	l_input.setOutput((float *)input);
	
	fp_preact_c1<<<128, 128>>>((float (*)[28])l_input.output, (float (*)[24][24])l_c1.preact, (float (*)[5][5])l_c1.weight);
	fp_bias_c1<<<128, 128>>>((float (*)[24][24])l_c1.preact, l_c1.bias);
	apply_sigmoid<<<128, 128>>>(l_c1.preact, l_c1.output, l_c1.O);

	fp_preact_r<<<128, 128>>>((float (*)[24][24])l_c1.preact, (float (*)[6][6])l_r.preact, (float (*)[4][4])l_r.weight);
	fp_bias_r<<<128, 128>>>((float (*)[6][6])l_r.preact, l_r.bias);

	fp_preact_c2<<<128, 128>>>((float (*)[24][24])l_c1.output, (float (*)[12][12])l_c2.preact, (float (*)[2][2])l_c2.weight);
	fp_bias_c2<<<128, 128>>>((float (*)[12][12])l_c2.preact, l_c2.bias);
	apply_sigmoid<<<128, 128>>>(l_c2.preact, l_c2.output, l_c2.O);

	fp_preact_c3<<<128, 128>>>((float (*)[12][12])l_c2.output, (float (*)[6][6])l_c3.preact, (float (*)[2][2])l_c3.weight);
	fp_bias_c3<<<128, 128>>>((float (*)[6][6])l_c3.preact, l_c3.bias);

	fp_add_res<<<128, 128>>>((float (*)[6][6])l_c3.preact, (float (*)[6][6])l_r.preact);
	
	apply_sigmoid<<<128, 128>>>(l_c3.preact, l_c3.output, l_c3.O);
	

	fp_preact_f<<<128, 128>>>((float (*)[6][6])l_c3.output, l_f.preact, (float (*)[6][6][6])l_f.weight);
	fp_bias_f<<<128, 128>>>(l_f.preact, l_f.bias);
	apply_sigmoid<<<128, 128>>>(l_f.preact, l_f.output, l_f.O);
	
	end = clock();
	return ((double) (end - start)) / CLOCKS_PER_SEC;
}

// Back propagation to update weights
static double back_pass()
{
	clock_t start, end;

	start = clock();

	bp_weight_f<<<128, 128>>>((float (*)[6][6][6])l_f.d_weight, l_f.d_preact, (float (*)[6][6])l_c3.output);
	bp_bias_f<<<128, 128>>>(l_f.bias, l_f.d_preact);

	bp_output_c3<<<128, 128>>>((float (*)[6][6])l_c3.d_output, (float (*)[6][6][6])l_f.weight, l_f.d_preact);
	bp_preact_c3<<<128, 128>>>((float (*)[6][6])l_c3.d_preact, (float (*)[6][6])l_c3.d_output, (float (*)[6][6])l_c3.preact);
	bp_weight_c3<<<128, 128>>>((float (*)[2][2])l_c3.d_weight, (float (*)[6][6])l_c3.d_preact, (float (*)[12][12])l_c2.output);
	bp_bias_c3<<<128, 128>>>(l_c3.bias, (float (*)[6][6])l_c3.d_preact);

	bp_output_c2<<<128, 128>>>((float (*)[12][12])l_c2.d_output, (float (*)[2][2])l_c3.weight, (float (*)[6][6])l_c3.d_preact);
	bp_preact_c2<<<128, 128>>>((float (*)[12][12])l_c2.d_preact, (float (*)[12][12])l_c2.d_output, (float (*)[12][12])l_c2.preact);
	bp_weight_c2<<<128, 128>>>((float (*)[2][2])l_c2.d_weight, (float (*)[12][12])l_c2.d_preact, (float (*)[24][24])l_c1.output);
	bp_bias_c2<<<128, 128>>>(l_c2.bias, (float (*)[12][12])l_c2.d_preact);

	bp_output_c1<<<128, 128>>>((float (*)[24][24])l_c1.d_output, (float (*)[2][2])l_c2.weight, (float (*)[12][12])l_c2.d_preact);
	bp_preact_c1<<<128, 128>>>((float (*)[24][24])l_c1.d_preact, (float (*)[24][24])l_c1.d_output, (float (*)[24][24])l_c1.preact);
	bp_weight_c1<<<128, 128>>>((float (*)[5][5])l_c1.d_weight, (float (*)[24][24])l_c1.d_preact, (float (*)[28])l_input.output);
	bp_bias_c1<<<128, 128>>>(l_c1.bias, (float (*)[24][24])l_c1.d_preact);


	apply_grad<<<128, 128>>>(l_f.weight, l_f.d_weight, l_f.M * l_f.N);
	apply_grad<<<128, 128>>>(l_c2.weight, l_c2.d_weight, l_c2.M * l_c2.N);
	apply_grad<<<128, 128>>>(l_c1.weight, l_c1.d_weight, l_c1.M * l_c1.N);

	end = clock();
	return ((double) (end - start)) / CLOCKS_PER_SEC;
}

// Unfold the input layer
static void unfold_input(double input[28][28], double unfolded[24*24][5*5])
{
	int a = 0;
	(void)unfold_input;

	for (int i = 0; i < 2; ++i)
		for (int j = 0; j < 2; ++j) {
			int b = 0;
			for (int x = i; x < i + 2; ++x)
				for (int y = j; y < j+2; ++y)
					unfolded[a][b++] = input[x][y];
			a++;
		}
}

static void learn()
{
	static cublasHandle_t blas;
	cublasCreate(&blas);

	float err;
	int iter = 20;
	
	double time_taken = 0.0;

	fprintf(stdout ,"Learning\n");

	while (iter < 0 || iter-- > 0) {
		err = 0.0f;

		for (int i = 0; i < train_cnt; ++i) {
			float tmp_err;

			time_taken += forward_pass(train_set[i].data);

			l_f.bp_clear();
			l_c2.bp_clear();
			l_c1.bp_clear();
			l_c3.bp_clear();
			// Euclid distance of train_set[i]
			makeError<<<10, 1>>>(l_f.d_preact, l_f.output, train_set[i].label, 10);
			cublasSnrm2(blas, 10, l_f.d_preact, 1, &tmp_err);
			err += tmp_err;

			time_taken += back_pass();
		}

		err /= train_cnt;
		double accuracy = 100 - double(err) * 100.0;
		fprintf(stdout, "accuracy: %.2lf%% , time_on_gpu: %lf sec\n", accuracy, time_taken);

		if (err < threshold) {
			fprintf(stdout, "Training complete, error less than threshold\n\n");
			break;
		}

	}
	
	fprintf(stdout, "\n Time - %lf s\n", time_taken);
}


// Returns label of given data (0-9)
static unsigned int classify(double data[28][28])
{
	float res[10];

	forward_pass(data);

	unsigned int max = 0;

	cudaMemcpy(res, l_f.output, sizeof(float) * 10, cudaMemcpyDeviceToHost);

	for (int i = 1; i < 10; ++i) {
		if (res[max] < res[i]) {
			max = i;
		}
	}

	return max;
}

// Perform forward propagation of test data
static void test()
{
	int error = 0;

	for (int i = 0; i < test_cnt; ++i) {
		if (classify(test_set[i].data) != test_set[i].label) {
			++error;
		}
	}
	double err_percent = double(error) / double(test_cnt) * 100.0;
	fprintf(stdout, "Error Rate: %.2lf%% , accuracy: %.2lf%%\n",err_percent,100-err_percent);
}
