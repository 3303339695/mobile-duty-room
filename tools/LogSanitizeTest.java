import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 验证日志清理逻辑：
 *   一、终端颜色码要清掉
 *   二、下载进度条要"原地覆盖"，不能堆成几百行
 *   三、中文、emoji、正常多行日志不能受影响
 */
public class LogSanitizeTest {

    private static final Pattern ANSI_PATTERN =
            Pattern.compile("\u001B\\[[0-9;?]*[ -/]*[@-~]");
    private static final Pattern BARE_ANSI_PATTERN =
            Pattern.compile("\\[[0-9]{1,3}(?:;[0-9]{1,3})*m");

    private static String sanitizeLogText(String raw) {
        if (raw == null || raw.isEmpty()) {
            return raw;
        }
        String text = ANSI_PATTERN.matcher(raw).replaceAll("");
        StringBuilder cleaned = new StringBuilder(text.length());
        Matcher matcher = BARE_ANSI_PATTERN.matcher(text);
        int cursor = 0;
        while (matcher.find()) {
            cleaned.append(text, cursor, matcher.start());
            cursor = matcher.end();
        }
        cleaned.append(text, cursor, text.length());

        StringBuilder result = new StringBuilder(cleaned.length());
        StringBuilder currentLine = new StringBuilder(160);
        for (int index = 0; index < cleaned.length(); index++) {
            char ch = cleaned.charAt(index);
            if (ch == '\r') {
                currentLine.setLength(0);
                continue;
            }
            if (ch == '\n') {
                result.append(currentLine).append('\n');
                currentLine.setLength(0);
                continue;
            }
            if (ch == '\t') {
                currentLine.append(ch);
                continue;
            }
            if (ch < 0x20 || ch == 0x7F || (ch >= 0x80 && ch <= 0x9F)) {
                continue;
            }
            currentLine.append(ch);
        }
        result.append(currentLine);
        return result.toString();
    }

    private static int failures = 0;

    private static void check(String label, String input, String expected) {
        String actual = sanitizeLogText(input);
        if (expected.equals(actual)) {
            System.out.println("通过：" + label);
        } else {
            failures++;
            System.out.println("失败：" + label);
            System.out.println("  期望：" + expected.replace("\r", "<CR>").replace("\n", "<LF>"));
            System.out.println("  实际：" + actual.replace("\r", "<CR>").replace("\n", "<LF>"));
        }
    }

    public static void main(String[] args) {
        // 一、进度条原地覆盖：只留最后一次的结果
        check("进度条只保留最后的进度",
                "9.7%######\r9.8%######\r10.4%######\r14.5%",
                "14.5%");

        // 二、进度条夹在正常日志中间
        check("进度条夹在日志中间时只覆盖它自己那一行",
                "正在下载某某（约 193 MB），请耐心等待\n"
                        + "#### 13.9%\r#### 14.1%\r#### 14.5%\n"
                        + "[完成] 下载结束\n",
                "正在下载某某（约 193 MB），请耐心等待\n"
                        + "#### 14.5%\n"
                        + "[完成] 下载结束\n");

        // 三、普通多行日志完全不受影响
        check("普通多行日志保持原样",
                "第一行\n第二行\n第三行\n",
                "第一行\n第二行\n第三行\n");

        // 四、颜色码要清掉（含 ESC 丢失后的残渣）
        check("颜色码被清除",
                "[32m[13:02:26][0m [Core] [1m[INFO][0m AstrBot started.",
                "[13:02:26] [Core] [INFO] AstrBot started.");

        // 五、中文与 emoji 不受影响
        check("中文与 emoji 保留",
                "中文 🐋 emoji ✅ 保留\t制表符",
                "中文 🐋 emoji ✅ 保留\t制表符");

        // 六、空行与连续换行
        check("连续换行保持",
                "A\n\n\nB\n",
                "A\n\n\nB\n");

        // 七、只有进度条没有换行（下载中途被读到的样子）
        check("单独一行的进度条只显示当前值",
                "## 45.0%\r## 45.2%\r## 45.5%",
                "## 45.5%");

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
