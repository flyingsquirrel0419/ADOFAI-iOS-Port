// Mono 인터프리터(MONO_AOT_MODE_INTERP) 검증용 테스트.
// Unity 게임 코드가 자주 쓰는 런타임 기능을 골고루 건드린다. 각 항목은 PASS/FAIL 한 줄을 찍는다.
//   mono Test.exe [all|callback|bench]
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

// Unity의 AOT.MonoPInvokeCallbackAttribute 와 같은 역할 (Mono는 이름만 본다)
[AttributeUsage(AttributeTargets.Method)]
class MonoPInvokeCallbackAttribute : Attribute {
    public MonoPInvokeCallbackAttribute(Type t) {}
}

struct Vec3 { public float x, y, z; public Vec3(float a, float b, float c) { x = a; y = b; z = c; } }

interface IShape { double Area(); }
class Circle : IShape { public double R; public double Area() => Math.PI * R * R; }
class Square : IShape { public double S; public double Area() => S * S; }

class Gen<T> {
    public T Value;
    public virtual string Describe<U>(U extra) => $"{typeof(T).Name}:{Value}/{typeof(U).Name}:{extra}";
}
class GenSub<T> : Gen<T> {
    public override string Describe<U>(U extra) => "sub:" + base.Describe(extra);
}

static class Program {
    static int pass, fail;

    static void Check(string name, Func<bool> f) {
        bool ok;
        string err = "";
        try { ok = f(); } catch (Exception e) { ok = false; err = " (" + e.GetType().Name + ": " + e.Message + ")"; }
        if (ok) pass++; else fail++;
        Console.WriteLine((ok ? "PASS " : "FAIL ") + name + err);
    }

    // ---- P/Invoke ----
    [DllImport("libc", EntryPoint = "strlen")] static extern IntPtr c_strlen(string s);
    [DllImport("libc", EntryPoint = "getpid")] static extern int c_getpid();

    delegate int IntCallback(int a, int b);
    delegate void VecCallback(ref Vec3 v);
    [DllImport("interptest")] static extern int it_call_int(IntCallback cb, int a, int b);
    [DllImport("interptest")] static extern float it_call_vec(VecCallback cb);
    [DllImport("interptest")] static extern int it_sum_vec(Vec3 v);

    [MonoPInvokeCallback(typeof(IntCallback))]
    static int Mul(int a, int b) => a * b;

    [MonoPInvokeCallback(typeof(VecCallback))]
    static void Scale(ref Vec3 v) { v.x *= 2; v.y *= 2; v.z *= 2; }

    static void Basics() {
        Check("arith/string", () => (40 + 2).ToString() + "x" == "42x");
        Check("valuetype generic List<Vec3>", () => {
            var l = new List<Vec3>();
            for (int i = 0; i < 100; i++) l.Add(new Vec3(i, i, i));
            return l.Sum(v => v.x) == 4950f;
        });
        Check("Dictionary<string,int>", () => {
            var d = new Dictionary<string, int>();
            for (int i = 0; i < 1000; i++) d["k" + i] = i;
            return d["k777"] == 777;
        });
        Check("Dictionary<Vec3-key long,Vec3>", () => {
            var d = new Dictionary<long, Vec3>();
            d[5] = new Vec3(1, 2, 3);
            return d[5].z == 3f;
        });
        Check("interface dispatch", () => new IShape[] { new Circle { R = 1 }, new Square { S = 2 } }.Sum(s => s.Area()) > 7.14);
        Check("generic virtual method", () => new GenSub<int> { Value = 3 }.Describe<double>(1.5) == "sub:Int32:3/Double:1.5");
        Check("LINQ", () => Enumerable.Range(0, 50).Where(i => i % 3 == 0).Select(i => i * i).OrderByDescending(i => i).First() == 2304);
        Check("exceptions", () => {
            try { throw new InvalidOperationException("x"); }
            catch (InvalidOperationException) { return true; }
        });
        Check("null deref -> NullReferenceException", () => {
            try { string s = null; return s.Length == 0; }
            catch (NullReferenceException) { return true; }
        });
        Check("delegates/closures", () => {
            int c = 0;
            Action a = () => c++;
            a += () => c += 10;
            a();
            return c == 11;
        });
        Check("reflection invoke", () => {
            var m = typeof(Program).GetMethod("Twice", BindingFlags.NonPublic | BindingFlags.Static);
            return (int)m.Invoke(null, new object[] { 21 }) == 42;
        });
        Check("reflection generic MakeGenericMethod", () => {
            var m = typeof(Program).GetMethod("Ident", BindingFlags.NonPublic | BindingFlags.Static).MakeGenericMethod(typeof(Vec3));
            var r = (Vec3)m.Invoke(null, new object[] { new Vec3(1, 2, 3) });
            return r.y == 2f;
        });
        Check("Activator.CreateInstance generic", () => Activator.CreateInstance(typeof(Gen<>).MakeGenericType(typeof(float))) != null);
        Check("threads", () => {
            int n = 0;
            var ts = Enumerable.Range(0, 4).Select(_ => new Thread(() => { for (int i = 0; i < 1000; i++) Interlocked.Increment(ref n); })).ToList();
            ts.ForEach(t => t.Start()); ts.ForEach(t => t.Join());
            return n == 4000;
        });
        Check("Task/async", () => Run().GetAwaiter().GetResult() == 7);
        Check("string.Format/culture", () => string.Format("{0:F2}", 3.14159) == "3.14");
        Check("pinvoke libc strlen", () => c_strlen("hello").ToInt64() == 5);
        Check("pinvoke libc getpid", () => c_getpid() > 0);
        Check("pinvoke struct by value", () => it_sum_vec(new Vec3(1, 2, 3)) == 6);
        Check("GC", () => { for (int i = 0; i < 200000; i++) { var _ = new byte[64]; } GC.Collect(); return true; });
    }

    static async Task<int> Run() { await Task.Delay(10); return await Task.Run(() => 7); }
    static int Twice(int x) => x * 2;
    static T Ident<T>(T x) => x;

    // 네이티브 -> 매니지드 역호출 (reverse P/Invoke). interp 모드에서 interp_in 래퍼가 필요한 부분.
    static void Callbacks() {
        Check("reverse pinvoke int(int,int)", () => it_call_int(Mul, 6, 7) == 42);
        Check("reverse pinvoke lambda", () => it_call_int((a, b) => a - b, 10, 3) == 7);
        Check("reverse pinvoke ref struct", () => it_call_vec(Scale) == 12f);
    }

    static void Bench() {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        // 1) 정수/분기 루프
        long acc = 0;
        for (int i = 0; i < 20_000_000; i++) acc += (i ^ (i >> 3)) & 7;
        var t1 = sw.Elapsed.TotalMilliseconds; sw.Restart();
        // 2) 부동소수 벡터 연산 (게임 로직 흉내)
        var arr = new Vec3[10000];
        for (int f = 0; f < 200; f++)
            for (int i = 0; i < arr.Length; i++) { arr[i].x += 0.1f; arr[i].y = arr[i].x * 0.5f; arr[i].z = (float)Math.Sin(arr[i].y); }
        var t2 = sw.Elapsed.TotalMilliseconds; sw.Restart();
        // 3) 객체/컬렉션/가상호출
        var shapes = new List<IShape>();
        for (int i = 0; i < 200000; i++) shapes.Add(i % 2 == 0 ? (IShape)new Circle { R = i } : new Square { S = i });
        double area = 0; foreach (var s in shapes) area += s.Area();
        var t3 = sw.Elapsed.TotalMilliseconds;
        Console.WriteLine($"BENCH int-loop {t1:F1} ms | vec3-float {t2:F1} ms | objects/virtual {t3:F1} ms | (chk {acc} {arr[5].z:F3} {area:E2})");
    }

    static int Main(string[] args) {
        string mode = args.Length > 0 ? args[0] : "all";
        Console.WriteLine("runtime: " + Type.GetType("Mono.Runtime")?.GetMethod("GetDisplayName", BindingFlags.NonPublic | BindingFlags.Static)?.Invoke(null, null));
        if (mode == "all" || mode == "basic") Basics();
        if (mode == "all" || mode == "callback") Callbacks();
        if (mode == "all" || mode == "bench") Bench();
        Console.WriteLine($"RESULT pass={pass} fail={fail}");
        return fail == 0 ? 0 : 1;
    }
}
