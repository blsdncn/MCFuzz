package test;

public class SmokeTest {
    public static void main(String[] args) {
        System.out.println("Hello from SmokeTest");
        for (int i = 0; i < 10; i++) {
            doWork(i);
        }
        System.out.println("Done");
    }

    static void doWork(int x) {
        if (x % 2 == 0) {
            System.out.println("Even: " + x);
        } else {
            System.out.println("Odd: " + x);
        }
    }
}
