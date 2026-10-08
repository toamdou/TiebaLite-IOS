# PiperSR-2x 模型归属（cc-by-4.0）

本目录的三个文件是 **PiperSR_2x**（2× 超分辨率，CoreML mlProgram）的原始 mlpackage 内容，随 App 包分发。

| 文件（本目录） | 原始路径（mlpackage 内） | 字节 |
|---|---|---|
| `PiperSR_2x_Manifest.json` | `PiperSR_2x.mlpackage/Manifest.json` | 617 |
| `PiperSR_2x_model.bin`（原 `model.mlmodel`） | `PiperSR_2x.mlpackage/Data/com.apple.CoreML/model.mlmodel` | 22,003 |
| `PiperSR_2x_weight.bin` | `PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights/weight.bin` | 905,560 |

- 来源：<https://huggingface.co/ModelPiper/PiperSR-2x>（repo sha `8daecfccbbe023de6580e7eecbff3d44a51d0b13`）
- 许可：**CC BY 4.0**（署名要求：保留本文件与来源链接）
- 文件名是**打包要求**，两条都不能改：
  1. 带 `PiperSR_2x_` 前缀 —— `app_resources` 按 basename 扁平落盘，原名 `Manifest.json` 会与其它资源撞名；
  2. 规格文件叫 `.bin` 而不是 `.mlmodel` —— rules_apple 见到 `.mlmodel` 会自动跑 `coremlc compile`，而扁平落盘的 `.mlmodel` 找不到同目录的 `weights/weight.bin`（实测构建失败：`Could not open .../weights/weight.bin`）。
- 运行期由 `TiebaSuperResolutionModelStore` 按 mlpackage 规范结构拼回目录（`Data/com.apple.CoreML/...`）后 `MLModel.compileModel` 一次并缓存到 Caches；若将来随包提供预编译 `.mlmodelc`，它会优先使用，代码无需改动。

接口（coremlcompiler 读出，不是 README 说法）：`input_image` IMAGE 128×128 32BGRA → `output_image` IMAGE 256×256 32BGRA；specificationVersion 6 / mlProgram（iOS 15+）。
