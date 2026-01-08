#include "bench_common.h"
#include <stdlib.h>

typedef struct Node {
    int key;
    struct Node *left;
    struct Node *right;
} Node;

static Node *node_insert(Node *root, int key) {
    if (root == NULL) {
        Node *n = (Node *)malloc(sizeof(Node));
        n->key = key;
        n->left = NULL;
        n->right = NULL;
        return n;
    }
    if (key < root->key) {
        root->left = node_insert(root->left, key);
    } else if (key > root->key) {
        root->right = node_insert(root->right, key);
    }
    return root;
}

static int node_search(Node *root, int key) {
    while (root != NULL) {
        if (key == root->key) return 1;
        root = (key < root->key) ? root->left : root->right;
    }
    return 0;
}

static void node_free(Node *root) {
    if (root == NULL) return;
    node_free(root->left);
    node_free(root->right);
    free(root);
}

static uint32_t lcg_next(uint32_t *state) {
    *state = (*state * 1664525u) + 1013904223u;
    return *state;
}

static double bench_binarytree(uint64_t node_count, uint64_t lookups) {
    Node *root = NULL;
    uint32_t state = 0xC0FFEEu;

    for (uint64_t i = 0; i < node_count; i += 1) {
        const int key = (int)(lcg_next(&state) % (uint32_t)(node_count * 4));
        root = node_insert(root, key);
    }

    state = 0xBEEFu;
    double checksum = 0.0;
    for (uint64_t i = 0; i < lookups; i += 1) {
        const int key = (int)(lcg_next(&state) % (uint32_t)(node_count * 4));
        checksum += (double)node_search(root, key);
    }

    node_free(root);
    return checksum;
}

int main(int argc, char **argv) {
    const char *feature_id = (argc > 1) ? argv[1] : "baseline";
    const int64_t timestamp = (int64_t)time(NULL);

    const uint64_t node_count = 400000;
    const uint64_t lookups = 2000000;

    const uint64_t start = bench_now_ns();
    const double checksum = bench_binarytree(node_count, lookups);
    const uint64_t end = bench_now_ns();

    const double duration_ms = (double)(end - start) / 1000000.0;
    bench_log_csv(timestamp, feature_id, "ref_c_binarytree_search", lookups, duration_ms, checksum);
    return 0;
}