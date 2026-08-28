import type { HybridObject } from 'react-native-nitro-modules';

/**
 * TiebaProtoNitro — proto 传输的 Nitro HybridObject（nitrogen 生成路线）。
 * 契约与 ObjC++ 手写版一致：请求体 ArrayBuffer 直入，响应为投影后 JSON 字符串。
 */
export interface TiebaProtoRequest {
  url: string;
  headers: Record<string, string>;
  /** multipart 表单字段（键, 值) 扁平对，顺序敏感（签名参与） */
  formFields: string[][];
  /** protobuf wire 格式请求体（protobufjs encode 产物，零拷贝过桥） */
  bodyBytes: ArrayBuffer;
  skipSign: boolean;
  responseType: string;
  requestId: string;
  timeoutMs?: number;
}

export interface TiebaProtoNitro
  extends HybridObject<{ ios: 'swift' }> {
  protoPost(request: TiebaProtoRequest): Promise<string>;
  version(): string;
}
