from abc import abstractmethod


class ISafetyFilter:
    """
    Safety filter interface
    """
    @abstractmethod
    def ck_cmd_safe(cmd : str) -> bool:
        pass

    @abstractmethod
    def ck_ret_msg_safe(msg : str) -> bool:
        pass