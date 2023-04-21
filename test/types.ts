type SignerWithAddress = any;

declare module "mocha" {
  export interface Context {
    deployer: SignerWithAddress;
    addrs: SignerWithAddress[];
  }
}
