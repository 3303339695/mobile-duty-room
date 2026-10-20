import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** 验证日志尾部读取的算法：分块跳过、限量读取、未知长度时保留尾部、中文切边。 */
public class LogTailTest {

    /** 不支持跳跃的流：验证跳过时是整块读掉，而不是一个字节一个字节地读。 */
    static final class NoSkipStream extends ByteArrayInputStream {
        int readCalls = 0;

        NoSkipStream(byte[] data) {
            super(data);
        }

        @Override
        public long skip(long n) {
            return 0;
        }

        @Override
        public int read(byte[] buffer, int offset, int length) {
            readCalls++;
            return super.read(buffer, offset, length);
        }
    }

    private static void skipBytes(InputStream input, long count) throws IOException {
        long remaining = count;
        byte[] buffer = new byte[64 * 1024];
        while (remaining > 0) {
            long step = input.skip(remaining);
            if (step > 0) {
                remaining -= step;
                continue;
            }
            int want = (int) Math.min(remaining, buffer.length);
            int read = input.read(buffer, 0, want);
            if (read <= 0) {
                return;
            }
            remaining -= read;
        }
    }

    private static byte[] readAtMost(InputStream input, int limit) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(
                Math.max(1024, Math.min(limit, 64 * 1024)));
        byte[] buffer = new byte[8192];
        while (output.size() < limit) {
            int want = Math.min(buffer.length, limit - output.size());
            int read = input.read(buffer, 0, want);
            if (read <= 0) {
                break;
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }

    private static byte[] readTailWhenSizeUnknown(InputStream input, int limit) throws IOException {
        int capacity = limit > 0 ? limit : 1024;
        byte[] ring = new byte[capacity];
        int filled = 0;
        byte[] buffer = new byte[8192];
        int read;
        while ((read = input.read(buffer)) > 0) {
            if (read >= capacity) {
                System.arraycopy(buffer, read - capacity, ring, 0, capacity);
                filled = capacity;
                continue;
            }
            int overflow = filled + read - capacity;
            if (overflow > 0) {
                System.arraycopy(ring, overflow, ring, 0, filled - overflow);
                filled -= overflow;
            }
            System.arraycopy(buffer, 0, ring, filled, read);
            filled += read;
        }
        byte[] result = new byte[filled];
        System.arraycopy(ring, 0, result, 0, filled);
        return result;
    }

    private static String trimLeadingUtf8(byte[] bytes, boolean trimmed) {
        int start = 0;
        if (trimmed) {
            while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
                start++;
            }
        }
        return new String(bytes, start, bytes.length - start, StandardCharsets.UTF_8);
    }

    private static int failures = 0;

    private static void check(String label, boolean ok, String detail) {
        if (ok) {
            System.out.println("通过：" + label);
        } else {
            failures++;
            System.out.println("失败：" + label + "  " + detail);
        }
    }

    public static void main(String[] args) throws Exception {
        // 一、普通流：跳过前 900 字节，只读最后 100 字节
        byte[] ascii = new byte[1000];
        for (int i = 0; i < ascii.length; i++) {
            ascii[i] = (byte) ('a' + (i % 26));
        }
        InputStream normal = new ByteArrayInputStream(ascii);
        skipBytes(normal, 900);
        byte[] tail = readAtMost(normal, 100);
        check("普通流只读到最后 100 字节", tail.length == 100
                && new String(tail, StandardCharsets.UTF_8)
                .equals(new String(ascii, 900, 100, StandardCharsets.UTF_8)),
                "长度=" + tail.length);

        // 二、不支持跳跃的流：结果必须一样，而且读取次数必须是"块级别"
        NoSkipStream stubborn = new NoSkipStream(ascii);
        skipBytes(stubborn, 900);
        byte[] stubbornTail = readAtMost(stubborn, 100);
        check("流不支持跳跃时结果一致", stubbornTail.length == 100, "长度=" + stubbornTail.length);
        check("流不支持跳跃时没有退化成逐字节读", stubborn.readCalls <= 4,
                "读取次数=" + stubborn.readCalls + "（应为个位数）");

        // 三、不知道总长度：边读边丢，只留尾部
        InputStream unknown = new ByteArrayInputStream(ascii);
        byte[] ringTail = readTailWhenSizeUnknown(unknown, 100);
        check("未知长度时保留了最后 100 字节",
                new String(ringTail, StandardCharsets.UTF_8)
                        .equals(new String(ascii, 900, 100, StandardCharsets.UTF_8)),
                "长度=" + ringTail.length);

        // 四、文件比上限小：全部读出来
        InputStream small = new ByteArrayInputStream(ascii);
        byte[] all = readAtMost(small, 256 * 1024);
        check("文件小于上限时全部读取", all.length == 1000, "长度=" + all.length);

        // 五、中文被切在中间：剥掉残字节后不能出现乱码方块
        String chinese = "一二三四五六七八九十";
        byte[] chineseBytes = chinese.getBytes(StandardCharsets.UTF_8);
        // 从第 2 个字节处切开，前 2 字节被丢弃，剩下的开头必然是续接字节
        byte[] cut = new byte[chineseBytes.length - 2];
        System.arraycopy(chineseBytes, 2, cut, 0, cut.length);
        String decoded = trimLeadingUtf8(cut, true);
        boolean noReplacement = decoded.indexOf('\uFFFD') < 0;
        check("中文从中间切开后不出现乱码方块", noReplacement, "解码结果=" + decoded);
        check("中文其余汉字完整", decoded.equals("二三四五六七八九十"), "解码结果=" + decoded);

        // 六、上限恰好等于文件大小
        InputStream exact = new ByteArrayInputStream(ascii);
        byte[] exactBytes = readAtMost(exact, 1000);
        check("上限等于文件大小时完整读取", exactBytes.length == 1000, "长度=" + exactBytes.length);

        System.out.println();
        if (failures == 0) {
            System.out.println("结果：全部通过");
            System.exit(0);
        } else {
            System.out.println("结果：失败 " + failures + " 项");
            System.exit(1);
        }
    }
}
