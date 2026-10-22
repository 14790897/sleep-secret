import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/ui/core/theme.dart';
import 'package:sleep_secret/ui/core/widgets/score_gauge.dart';

void main() {
  test('评分越高越绿，鼾声指数越高越红', () {
    // 列表圆环和详情页大环共用这一条配色规则。方向弄反的话，
    // 评分 98 会被画成红色（原来就是这个 bug）。
    expect(
      gaugeColorFor(value: 98, higherIsBetter: true),
      AppColors.statusGood,
      reason: '98 分的夜晚应该是绿的',
    );
    expect(
      gaugeColorFor(value: 15),
      AppColors.statusGood,
      reason: '鼾声指数 15% 很低，应该是绿的',
    );
    expect(
      gaugeColorFor(value: 50, higherIsBetter: true),
      AppColors.statusWarning,
      reason: '50 分是中间档',
    );
    expect(
      gaugeColorFor(value: 90),
      AppColors.statusCritical,
      reason: '鼾声指数 90% 很高，应该是红的',
    );
  });
}
