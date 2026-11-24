// Test.cs 의 P/Invoke / reverse P/Invoke 상대편 네이티브 라이브러리
typedef struct { float x, y, z; } Vec3;

int it_call_int(int (*cb)(int, int), int a, int b) { return cb(a, b); }

float it_call_vec(void (*cb)(Vec3 *)) {
    Vec3 v = {1, 2, 3};
    cb(&v);
    return v.x + v.y + v.z;
}

int it_sum_vec(Vec3 v) { return (int)(v.x + v.y + v.z); }
